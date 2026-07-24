// MindMap — the vault as a collapsible left-to-right tree.
// Vault -> notebooks -> tag groups -> notes. Quiet by default: only the
// notebook spines show until a branch is expanded. Typed edges appear as
// dashed cross-links when hovering a note.
import * as d3 from "../vendor/d3-hierarchy.js"

const KIND_COLORS = {
  extends: "#6366f1",
  contradicts: "#e11d48",
  example_of: "#059669",
  references: "#0891b2",
  same_topic: "#d97706",
}
const ROW = 26
const COL = 250

const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi)

export default {
  mounted() {
    this.svg = this.el.querySelector("svg")
    this.viewport = this.el.querySelector("[data-viewport]")
    this.linkLayer = this.el.querySelector("[data-links]")
    this.overlayLayer = this.el.querySelector("[data-overlay]")
    this.nodeLayer = this.el.querySelector("[data-nodes]")
    this.reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    this.tree = null
    this.expanded = new Set(["root"])
    this.searchExpanded = null // extra uids opened by an active search
    this.matchUids = null
    this.positions = new Map() // uid -> {x, y} after layout
    this.parentOf = new Map()
    this.noteLinks = new Map() // note id -> [{other, kind}]
    this.k = 1; this.tx = 40; this.ty = 40
    this.pointers = new Map()
    this.moved = 0
    this.pinchDist = null

    this.handleEvent("mindmap", ({tree, links}) => {
      this.tree = tree
      this.indexTree(tree, null, null)
      this.noteLinks = new Map()
      for (const l of links) {
        if (!this.noteLinks.has(l.source)) this.noteLinks.set(l.source, [])
        if (!this.noteLinks.has(l.target)) this.noteLinks.set(l.target, [])
        this.noteLinks.get(l.source).push({other: l.target, kind: l.kind})
        this.noteLinks.get(l.target).push({other: l.source, kind: l.kind})
      }
      this.layout()
      this.fit()
    })

    this.bindPanZoom()
    this.bindSearch()
  },

  destroyed() {
    window.removeEventListener("keydown", this.slashShortcut)
  },

  indexTree(node, parent, color) {
    node.color = node.color || color
    this.parentOf.set(node.uid, parent?.uid || null)
    for (const child of node.children || []) this.indexTree(child, node, node.color)
  },

  nodeByUid(uid, node = this.tree) {
    if (node.uid === uid) return node
    for (const child of node.children || []) {
      const found = this.nodeByUid(uid, child)
      if (found) return found
    }
    return null
  },

  // ---- layout + render ----------------------------------------------------

  isOpen(uid) {
    return this.expanded.has(uid) || this.searchExpanded?.has(uid)
  },

  prune(node) {
    const open = node.kind === "root" || this.isOpen(node.uid)
    return {
      data: node,
      children: open && node.children ? node.children.map((c) => this.prune(c)) : null,
    }
  },

  layout() {
    if (!this.tree) return
    const root = d3.hierarchy(this.prune(this.tree), (d) => d.children)
    d3.tree().nodeSize([ROW, COL])(root)

    this.positions.clear()
    this.linkLayer.replaceChildren()
    this.overlayLayer.replaceChildren()
    this.nodeLayer.replaceChildren()

    for (const h of root.descendants()) {
      const node = h.data.data
      this.positions.set(node.uid, {x: h.x, y: h.y})
      if (h.parent && h.parent.data.data.kind !== "root") {
        this.linkLayer.appendChild(this.linkPath(h.parent, h, node.color))
      }
      this.nodeLayer.appendChild(this.nodeGroup(node, h))
    }
  },

  linkPath(parent, child, color) {
    const p = document.createElementNS("http://www.w3.org/2000/svg", "path")
    const sx = parent.y + 8, sy = parent.x
    const tx = child.y - 8, ty = child.x
    const mid = (sx + tx) / 2
    p.setAttribute("d", `M ${sx} ${sy} C ${mid} ${sy}, ${mid} ${ty}, ${tx} ${ty}`)
    p.setAttribute("fill", "none")
    p.setAttribute("stroke", color || "currentColor")
    p.setAttribute("stroke-width", "1.5")
    p.setAttribute("stroke-opacity", "0.5")
    return p
  },

  nodeGroup(node, h) {
    const g = document.createElementNS("http://www.w3.org/2000/svg", "g")
    g.setAttribute("transform", `translate(${h.y} ${h.x})`)

    const isBranch = node.kind === "notebook" || node.kind === "tag" || node.kind === "root"
    const match = this.matchUids?.has(node.uid)

    if (isBranch) {
      const open = node.kind === "root" || this.isOpen(node.uid)
      const dot = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      dot.setAttribute("r", "4")
      dot.setAttribute("fill", open ? "none" : node.color || "currentColor")
      dot.setAttribute("stroke", node.color || "currentColor")
      dot.setAttribute("stroke-width", "1.5")
      g.appendChild(dot)

      const label = this.textEl(node.name, 10, match)
      label.setAttribute("font-weight", node.kind === "notebook" ? "600" : "500")
      g.appendChild(label)

      if (node.count != null) {
        const count = this.textEl(String(node.count), 10, false)
        count.setAttribute("opacity", "0.45")
        count.setAttribute("font-size", "10")
        const w = this.measure(node.name, node.kind === "notebook" ? 600 : 500)
        count.setAttribute("x", 16 + w)
        g.appendChild(count)
      }

      if (node.kind !== "root") {
        g.classList.add("cursor-pointer")
        g.addEventListener("click", (e) => {
          e.stopPropagation()
          if (this.moved > 5) return
          this.expanded.has(node.uid)
            ? this.expanded.delete(node.uid)
            : this.expanded.add(node.uid)
          this.layout()
        })
      }
    } else {
      const dot = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      dot.setAttribute("r", "2.5")
      dot.setAttribute("fill", node.color || "currentColor")
      dot.setAttribute("fill-opacity", "0.7")
      g.appendChild(dot)

      const links = this.noteLinks.get(node.id)
      const title = node.name.length > 42 ? node.name.slice(0, 41) + "…" : node.name
      const label = this.textEl(title, 9, match)
      g.appendChild(label)

      if (links?.length) {
        const badge = this.textEl(`⇄${links.length}`, 9, false)
        badge.setAttribute("font-size", "9")
        badge.setAttribute("opacity", "0.5")
        badge.setAttribute("x", 13 + this.measure(title, 400))
        g.appendChild(badge)
      }

      g.classList.add("cursor-pointer")
      g.addEventListener("click", (e) => {
        e.stopPropagation()
        if (this.moved <= 5) this.pushEvent("open_note", {id: node.id})
      })
      g.addEventListener("mouseenter", () => this.showCrossLinks(node))
      g.addEventListener("mouseleave", () => this.overlayLayer.replaceChildren())
    }
    return g
  },

  textEl(text, x, match) {
    const t = document.createElementNS("http://www.w3.org/2000/svg", "text")
    t.setAttribute("x", x)
    t.setAttribute("dy", "0.32em")
    t.setAttribute("font-size", "12")
    t.setAttribute("fill", "currentColor")
    if (match) {
      t.setAttribute("font-weight", "700")
      t.setAttribute("text-decoration", "underline")
    }
    t.textContent = text
    return t
  },

  measure(text, weight) {
    this.measureCtx ||= document.createElement("canvas").getContext("2d")
    this.measureCtx.font = `${weight} 12px system-ui, -apple-system, sans-serif`
    return this.measureCtx.measureText(text).width
  },

  showCrossLinks(note) {
    this.overlayLayer.replaceChildren()
    const from = this.positions.get(note.uid)
    if (!from) return
    for (const {other, kind} of this.noteLinks.get(note.id) || []) {
      const to = this.positions.get(`note-${other}`)
      if (!to) continue
      const p = document.createElementNS("http://www.w3.org/2000/svg", "path")
      const mid = (from.y + to.y) / 2
      p.setAttribute(
        "d",
        `M ${from.y} ${from.x} C ${mid + 60} ${from.x}, ${mid + 60} ${to.x}, ${to.y} ${to.x}`
      )
      p.setAttribute("fill", "none")
      p.setAttribute("stroke", KIND_COLORS[kind] || "currentColor")
      p.setAttribute("stroke-width", "1.5")
      p.setAttribute("stroke-dasharray", "4 3")
      p.setAttribute("stroke-opacity", "0.85")
      this.overlayLayer.appendChild(p)
    }
  },

  // ---- view control -------------------------------------------------------

  applyTransform() {
    this.viewport.setAttribute(
      "transform",
      `translate(${this.tx} ${this.ty}) scale(${this.k})`
    )
  },

  animateView(k, tx, ty) {
    if (this.reducedMotion) {
      this.k = k; this.tx = tx; this.ty = ty
      this.applyTransform()
      return
    }
    const from = {k: this.k, tx: this.tx, ty: this.ty}
    const t0 = performance.now()
    const step = (now) => {
      let t = clamp((now - t0) / 240, 0, 1)
      t = t * t * (3 - 2 * t)
      this.k = from.k + (k - from.k) * t
      this.tx = from.tx + (tx - from.tx) * t
      this.ty = from.ty + (ty - from.ty) * t
      this.applyTransform()
      if (t < 1) requestAnimationFrame(step)
    }
    requestAnimationFrame(step)
  },

  fit() {
    const box = this.viewport.getBBox()
    if (box.width === 0) return
    const rect = this.svg.getBoundingClientRect()
    const k = clamp(Math.min(rect.width / (box.width + 120), rect.height / (box.height + 80)), 0.3, 1.25)
    this.animateView(
      k,
      rect.width / 2 - (box.x + box.width / 2) * k,
      rect.height / 2 - (box.y + box.height / 2) * k
    )
  },

  centerOn(uid) {
    const pos = this.positions.get(uid)
    if (!pos) return
    const rect = this.svg.getBoundingClientRect()
    const k = Math.max(this.k, 0.9)
    this.animateView(k, rect.width / 2 - pos.y * k, rect.height / 2 - pos.x * k)
  },

  zoomAt(clientX, clientY, factor) {
    const next = clamp(this.k * factor, 0.2, 4)
    const rect = this.svg.getBoundingClientRect()
    const px = clientX - rect.left, py = clientY - rect.top
    this.tx = px - (next / this.k) * (px - this.tx)
    this.ty = py - (next / this.k) * (py - this.ty)
    this.k = next
    this.applyTransform()
  },

  bindPanZoom() {
    this.el.addEventListener("wheel", (e) => {
      e.preventDefault()
      this.zoomAt(e.clientX, e.clientY, e.deltaY < 0 ? 1.12 : 0.89)
    }, {passive: false})

    this.el.addEventListener("pointerdown", (e) => {
      if (e.target.closest("[data-ui]")) return
      this.pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})
      if (this.pointers.size === 1) this.moved = 0
      this.pinchDist = null
    })

    this.el.addEventListener("pointermove", (e) => {
      if (!this.pointers.has(e.pointerId)) return
      const prev = this.pointers.get(e.pointerId)
      this.pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})

      if (this.pointers.size === 2) {
        const [a, b] = [...this.pointers.values()]
        const dist = Math.hypot(a.x - b.x, a.y - b.y)
        if (this.pinchDist) this.zoomAt((a.x + b.x) / 2, (a.y + b.y) / 2, dist / this.pinchDist)
        this.pinchDist = dist
        this.moved += 10
        return
      }

      const dx = e.clientX - prev.x, dy = e.clientY - prev.y
      this.moved += Math.abs(dx) + Math.abs(dy)
      if (this.moved > 5) {
        if (!this.el.hasPointerCapture(e.pointerId)) this.el.setPointerCapture(e.pointerId)
        this.tx += dx
        this.ty += dy
        this.applyTransform()
      }
    })

    const release = (e) => {
      this.pointers.delete(e.pointerId)
      this.pinchDist = null
    }
    this.el.addEventListener("pointerup", release)
    this.el.addEventListener("pointercancel", release)

    this.el.addEventListener("dblclick", (e) => {
      if (!e.target.closest("[data-ui]")) this.fit()
    })

    this.el.querySelector('[data-zoom="in"]').addEventListener("click", () => {
      const r = this.svg.getBoundingClientRect()
      this.zoomAt(r.left + r.width / 2, r.top + r.height / 2, 1.3)
    })
    this.el.querySelector('[data-zoom="out"]').addEventListener("click", () => {
      const r = this.svg.getBoundingClientRect()
      this.zoomAt(r.left + r.width / 2, r.top + r.height / 2, 0.77)
    })
    this.el.querySelector('[data-zoom="reset"]').addEventListener("click", () => {
      this.expanded = new Set(["root"])
      this.layout()
      this.fit()
    })
  },

  // ---- search -------------------------------------------------------------

  ancestorsOf(uid) {
    const out = []
    let cur = this.parentOf.get(uid)
    while (cur) {
      out.push(cur)
      cur = this.parentOf.get(cur)
    }
    return out
  },

  collectMatches(q) {
    const matches = []
    const walk = (node) => {
      if (node.kind !== "root" && node.name.toLowerCase().includes(q)) matches.push(node)
      for (const c of node.children || []) walk(c)
    }
    walk(this.tree)
    return matches
  },

  bindSearch() {
    const input = this.el.querySelector("[data-search]")
    const results = this.el.querySelector("[data-results]")
    const clear = this.el.querySelector("[data-search-clear]")

    const hideResults = () => {
      results.classList.add("hidden")
      results.replaceChildren()
      this.resultNodes = []
    }

    const clearSearch = () => {
      input.value = ""
      clear.classList.add("hidden")
      this.searchExpanded = null
      this.matchUids = null
      hideResults()
      this.layout()
    }

    const select = (node) => {
      hideResults()
      input.blur()
      this.layout()
      this.centerOn(node.uid)
    }

    const showResults = (nodes) => {
      this.resultNodes = nodes
      results.replaceChildren()
      if (nodes.length === 0) {
        const p = document.createElement("p")
        p.className = "px-3 py-2 text-xs opacity-50"
        p.textContent = "No matches"
        results.appendChild(p)
      }
      for (const n of nodes.slice(0, 8)) {
        const row = document.createElement("button")
        row.className = "flex w-full items-center gap-2 px-3 py-1.5 text-left hover:bg-base-200"
        const dot = document.createElement("span")
        dot.className = "size-2 rounded-full shrink-0"
        dot.style.background = n.color || "#64748b"
        const text = document.createElement("span")
        text.className = "block truncate text-sm"
        text.textContent = n.name
        row.append(dot, text)
        row.addEventListener("mousedown", (e) => {
          e.preventDefault()
          select(n)
        })
        results.appendChild(row)
      }
      results.classList.remove("hidden")
    }

    input.addEventListener("input", () => {
      const q = input.value.trim().toLowerCase()
      clear.classList.toggle("hidden", q === "")
      if (q.length < 2) {
        this.searchExpanded = null
        this.matchUids = null
        hideResults()
        this.layout()
        return
      }
      const matches = this.collectMatches(q).slice(0, 60)
      this.matchUids = new Set(matches.map((m) => m.uid))
      this.searchExpanded = new Set(matches.flatMap((m) => this.ancestorsOf(m.uid)))
      showResults(matches)
      this.layout()
    })

    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && this.resultNodes?.length) select(this.resultNodes[0])
      if (e.key === "Escape") { clearSearch(); input.blur() }
      e.stopPropagation()
    })

    input.addEventListener("blur", () => setTimeout(hideResults, 150))
    clear.addEventListener("click", () => { clearSearch(); input.focus() })

    this.slashShortcut = (e) => {
      if (e.key !== "/" || e.target.closest("input, textarea, select")) return
      e.preventDefault()
      input.focus()
      input.select()
    }
    window.addEventListener("keydown", this.slashShortcut)
  },
}
