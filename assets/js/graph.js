// Constellation — the vault knowledge graph as a deep-sky survey.
// Nodes are glowing stars grouped into per-notebook constellations, typed
// edges are curved light bridges, similarity edges are optional faint
// threads. Hovering lifts one constellation out of the dimmed sky.
import * as d3 from "../vendor/d3-force.js"

const SKY = "#0a0d18"
const SKY_GLOW = "rgba(28, 36, 66, 0.55)"
const LABEL = "#e6e9f5"
const EDGE_COLORS = {
  related: "#5a6486",
  extends: "#8b9cf7",
  contradicts: "#ef7d95",
  example_of: "#7fd8a0",
  references: "#7dd0e8",
  same_topic: "#e8c47d",
}

const dpr = () => window.devicePixelRatio || 1
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi)
const smoothstep = (t) => { t = clamp(t, 0, 1); return t * t * (3 - 2 * t) }

export default {
  mounted() {
    this.canvas = this.el.querySelector("canvas")
    this.ctx = this.canvas.getContext("2d")
    this.tooltip = this.el.querySelector("[data-tooltip]")
    this.reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    this.nodes = []
    this.links = []
    this.adjacent = new Map()
    this.k = 1; this.tx = 0; this.ty = 0
    this.hover = null
    this.pinned = null // search selection: stays focused until dismissed
    this.searchMatches = null
    this.focus = 0 // 0 = full sky, 1 = neighborhood lifted
    this.showSimilarity = false
    this.pointers = new Map()
    this.moved = 0
    this.pinchDist = null
    this.dragNode = null
    this.framePending = false
    this.fittedOnce = false

    this.resize = () => {
      const rect = this.el.getBoundingClientRect()
      this.w = rect.width; this.h = rect.height
      this.canvas.width = rect.width * dpr()
      this.canvas.height = rect.height * dpr()
      this.schedule()
    }
    this.observer = new ResizeObserver(this.resize)
    this.observer.observe(this.el)
    this.resize()

    this.handleEvent("graph", ({nodes, edges}) => this.start(nodes, edges))
    this.bindInteractions()
    this.bindSearch()
  },

  destroyed() {
    this.sim?.stop()
    this.observer?.disconnect()
    window.removeEventListener("keydown", this.slashShortcut)
  },

  start(nodes, edges) {
    this.nodes = nodes
    this.links = edges
    this.typedLinks = edges.filter((e) => e.kind !== "related")
    this.simLinks = edges.filter((e) => e.kind === "related")

    // per-notebook anchors on a ring, so notebooks settle into constellations
    const notebooks = [...new Set(nodes.map((n) => n.notebook || ""))]
    const ringR = Math.min(this.w, this.h) * 0.26
    const anchors = new Map(notebooks.map((name, i) => {
      const angle = (i / notebooks.length) * Math.PI * 2 - Math.PI / 2
      return [name, {
        x: this.w / 2 + Math.cos(angle) * ringR,
        y: this.h / 2 + Math.sin(angle) * ringR,
      }]
    }))

    this.adjacent = new Map(nodes.map((n) => [n.id, new Set()]))
    for (const e of edges) {
      this.adjacent.get(e.source)?.add(e.target)
      this.adjacent.get(e.target)?.add(e.source)
    }

    // seed positions near the notebook anchor so constellations form calmly
    for (const n of nodes) {
      const a = anchors.get(n.notebook || "")
      const jitter = () => (Math.random() - 0.5) * 120
      n.x = a.x + jitter(); n.y = a.y + jitter()
    }

    this.sim = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(edges).id((d) => d.id)
        .distance((l) => l.kind === "related" ? 46 : 74)
        .strength((l) => l.kind === "related" ? 0.22 * l.weight : 0.45))
      .force("charge", d3.forceManyBody().strength(-46).theta(0.9))
      .force("collide", d3.forceCollide((d) => this.radius(d) + 3.5))
      .force("x", d3.forceX((d) => anchors.get(d.notebook || "").x).strength(0.05))
      .force("y", d3.forceY((d) => anchors.get(d.notebook || "").y).strength(0.05))
      .on("tick", () => {
        if (!this.fittedOnce && this.sim.alpha() < 0.35) {
          this.fittedOnce = true
          this.fit(false)
        }
        this.schedule()
      })
  },

  radius(n) {
    return Math.min(2.6 + Math.sqrt(n.degree) * 1.35, 13)
  },

  // ---- rendering ----------------------------------------------------------

  schedule() {
    if (this.framePending) return
    this.framePending = true
    requestAnimationFrame(() => { this.framePending = false; this.render() })
  },

  render() {
    const ctx = this.ctx
    const d = dpr()

    // night sky with a soft nebular center
    ctx.setTransform(d, 0, 0, d, 0, 0)
    ctx.fillStyle = SKY
    ctx.fillRect(0, 0, this.w, this.h)
    const sky = ctx.createRadialGradient(
      this.w / 2, this.h / 2, 0,
      this.w / 2, this.h / 2, Math.max(this.w, this.h) * 0.7
    )
    sky.addColorStop(0, SKY_GLOW)
    sky.addColorStop(1, "rgba(10, 13, 24, 0)")
    ctx.fillStyle = sky
    ctx.fillRect(0, 0, this.w, this.h)

    if (!this.nodes.length) return

    // one focus model: a hovered/pinned star lifts its neighborhood; an
    // active search lifts every match. Everything else dims.
    const focusNode = this.hover || this.pinned
    const matches = focusNode ? null : this.searchMatches
    const target = focusNode || matches ? 1 : 0
    if (Math.abs(this.focus - target) > 0.01) {
      this.focus += (target - this.focus) * (this.reducedMotion ? 1 : 0.22)
      this.schedule()
    } else {
      this.focus = target
    }

    const neighbors = focusNode ? this.adjacent.get(focusNode.id) : null
    const inFocus = (n) => {
      if (focusNode) return n === focusNode || neighbors?.has(n.id)
      if (matches) return matches.has(n.id)
      return true
    }
    const dimmed = 1 - 0.88 * this.focus

    ctx.setTransform(d * this.k, 0, 0, d * this.k, d * this.tx, d * this.ty)

    // edges: curved bridges of light
    const drawLink = (l, baseAlpha, width) => {
      const s = l.source, t = l.target
      const lit = focusNode && (s === focusNode || t === focusNode)
      const alpha = lit ? Math.min(baseAlpha * 3, 0.9) : baseAlpha * (target ? dimmed : 1)
      if (alpha < 0.015) return
      const mx = (s.x + t.x) / 2, my = (s.y + t.y) / 2
      const dx = t.x - s.x, dy = t.y - s.y
      const len = Math.hypot(dx, dy) || 1
      const bow = ((s.id + t.id) % 2 === 0 ? 1 : -1) * len * 0.07
      ctx.strokeStyle = EDGE_COLORS[l.kind] || EDGE_COLORS.related
      ctx.globalAlpha = alpha
      ctx.lineWidth = (lit ? width * 1.6 : width) / this.k
      ctx.beginPath()
      ctx.moveTo(s.x, s.y)
      ctx.quadraticCurveTo(mx - (dy / len) * bow, my + (dx / len) * bow, t.x, t.y)
      ctx.stroke()
    }

    if (this.showSimilarity) {
      for (const l of this.simLinks) drawLink(l, 0.08, 0.6)
    }
    for (const l of this.typedLinks) drawLink(l, 0.14 + 0.2 * l.weight, 1.15)
    ctx.globalAlpha = 1

    // glow pass: stars bloom additively
    ctx.globalCompositeOperation = "lighter"
    for (const n of this.nodes) {
      const r = this.radius(n)
      const a = (inFocus(n) ? 0.42 : 0.42 * dimmed)
      if (a < 0.02) continue
      const g = ctx.createRadialGradient(n.x, n.y, 0, n.x, n.y, r * 3)
      g.addColorStop(0, this.withAlpha(n.color, a))
      g.addColorStop(1, this.withAlpha(n.color, 0))
      ctx.fillStyle = g
      ctx.beginPath()
      ctx.arc(n.x, n.y, r * 3, 0, Math.PI * 2)
      ctx.fill()
    }
    ctx.globalCompositeOperation = "source-over"

    // core pass: bright-hearted discs
    for (const n of this.nodes) {
      const r = this.radius(n)
      ctx.globalAlpha = inFocus(n) ? 1 : dimmed * 0.7
      const g = ctx.createRadialGradient(n.x - r * 0.3, n.y - r * 0.3, 0, n.x, n.y, r)
      g.addColorStop(0, "#f4f6ff")
      g.addColorStop(0.35, n.color)
      g.addColorStop(1, this.withAlpha(n.color, 0.75))
      ctx.fillStyle = g
      ctx.beginPath()
      ctx.arc(n.x, n.y, r, 0, Math.PI * 2)
      ctx.fill()
    }
    ctx.globalAlpha = 1

    // focus ring
    if (focusNode) {
      ctx.strokeStyle = this.withAlpha(focusNode.color, 0.9)
      ctx.lineWidth = 1.4 / this.k
      ctx.beginPath()
      ctx.arc(focusNode.x, focusNode.y, this.radius(focusNode) + 4 / this.k, 0, Math.PI * 2)
      ctx.stroke()
    }

    // labels in screen space, fading in with zoom
    ctx.setTransform(d, 0, 0, d, 0, 0)
    ctx.font = "500 11px system-ui, -apple-system, sans-serif"
    ctx.textAlign = "center"
    const zoomAlpha = smoothstep((this.k - 0.8) / 0.7)
    for (const n of this.nodes) {
      let a
      if (focusNode || matches) {
        a = inFocus(n) ? 1 : 0
      } else {
        a = n.degree >= 3 || this.k > 2.2 ? zoomAlpha : 0
      }
      if (a < 0.03) continue
      const sx = n.x * this.k + this.tx
      const sy = n.y * this.k + this.ty + this.radius(n) * this.k + 13
      if (sx < -80 || sx > this.w + 80 || sy < 0 || sy > this.h + 20) continue
      const text = n.title.length > 34 ? n.title.slice(0, 33) + "…" : n.title
      ctx.globalAlpha = a
      ctx.shadowColor = "rgba(5, 7, 15, 0.9)"
      ctx.shadowBlur = 4
      ctx.fillStyle = LABEL
      ctx.fillText(text, sx, sy)
      ctx.shadowBlur = 0
    }
    ctx.globalAlpha = 1
  },

  withAlpha(hex, a) {
    const n = parseInt(hex.slice(1), 16)
    return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`
  },

  // ---- view control -------------------------------------------------------

  toWorld(clientX, clientY) {
    const rect = this.canvas.getBoundingClientRect()
    return {
      x: (clientX - rect.left - this.tx) / this.k,
      y: (clientY - rect.top - this.ty) / this.k,
    }
  },

  zoomAt(clientX, clientY, factor) {
    const next = clamp(this.k * factor, 0.15, 9)
    const rect = this.canvas.getBoundingClientRect()
    const px = clientX - rect.left, py = clientY - rect.top
    this.tx = px - (next / this.k) * (px - this.tx)
    this.ty = py - (next / this.k) * (py - this.ty)
    this.k = next
    this.schedule()
  },

  animateView(k, tx, ty) {
    if (this.reducedMotion) {
      this.k = k; this.tx = tx; this.ty = ty
      this.schedule()
      return
    }
    const from = {k: this.k, tx: this.tx, ty: this.ty}
    const t0 = performance.now()
    const step = (now) => {
      const t = smoothstep(clamp((now - t0) / 260, 0, 1))
      this.k = from.k + (k - from.k) * t
      this.tx = from.tx + (tx - from.tx) * t
      this.ty = from.ty + (ty - from.ty) * t
      this.render()
      if (t < 1) requestAnimationFrame(step)
    }
    requestAnimationFrame(step)
  },

  fit(animate = true) {
    if (!this.nodes.length) return
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
    for (const n of this.nodes) {
      x0 = Math.min(x0, n.x); y0 = Math.min(y0, n.y)
      x1 = Math.max(x1, n.x); y1 = Math.max(y1, n.y)
    }
    const pad = 70
    const k = clamp(Math.min(
      this.w / (x1 - x0 + pad * 2),
      this.h / (y1 - y0 + pad * 2)
    ), 0.15, 1.6)
    const tx = this.w / 2 - ((x0 + x1) / 2) * k
    const ty = this.h / 2 - ((y0 + y1) / 2) * k
    animate ? this.animateView(k, tx, ty) : (this.k = k, this.tx = tx, this.ty = ty, this.schedule())
  },

  zoomCenter(factor) {
    const rect = this.canvas.getBoundingClientRect()
    this.zoomAt(rect.left + rect.width / 2, rect.top + rect.height / 2, factor)
  },

  flyTo(node) {
    const k = Math.max(this.k, 1.6)
    this.animateView(k, this.w / 2 - node.x * k, this.h / 2 - node.y * k)
  },

  // ---- search -------------------------------------------------------------

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
      this.searchMatches = null
      this.pinned = null
      hideResults()
      this.schedule()
    }
    this.clearSearch = clearSearch

    const showResults = (nodes) => {
      this.resultNodes = nodes
      results.replaceChildren()
      if (nodes.length === 0) {
        const p = document.createElement("p")
        p.className = "px-3 py-2 text-xs text-slate-500"
        p.textContent = "No matching notes"
        results.appendChild(p)
      }
      for (const n of nodes) {
        const row = document.createElement("button")
        row.className = "flex w-full items-center gap-2 px-3 py-1.5 text-left hover:bg-white/5"
        const dot = document.createElement("span")
        dot.className = "size-2 rounded-full shrink-0"
        dot.style.background = n.color
        const text = document.createElement("span")
        text.className = "min-w-0"
        const title = document.createElement("span")
        title.className = "block truncate text-sm text-slate-100"
        title.textContent = n.title
        const notebook = document.createElement("span")
        notebook.className = "block text-[10px] uppercase tracking-wider text-slate-500"
        notebook.textContent = n.notebook || "Unfiled"
        text.append(title, notebook)
        row.append(dot, text)
        row.addEventListener("mousedown", (e) => {
          e.preventDefault()
          select(n)
        })
        results.appendChild(row)
      }
      results.classList.remove("hidden")
    }

    const select = (node) => {
      this.pinned = node
      this.searchMatches = null
      hideResults()
      input.blur()
      this.flyTo(node)
      this.schedule()
    }

    input.addEventListener("input", () => {
      const q = input.value.trim().toLowerCase()
      clear.classList.toggle("hidden", q === "")
      this.pinned = null
      if (q.length < 2) {
        this.searchMatches = null
        hideResults()
        this.schedule()
        return
      }
      const found = this.nodes
        .filter((n) =>
          n.title.toLowerCase().includes(q) || (n.notebook || "").toLowerCase().includes(q))
        .sort((a, b) => b.degree - a.degree)
      this.searchMatches = new Set(found.map((n) => n.id))
      showResults(found.slice(0, 8))
      this.schedule()
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

  // ---- interactions -------------------------------------------------------

  hitTest(clientX, clientY) {
    if (!this.sim) return null
    const p = this.toWorld(clientX, clientY)
    return this.sim.find(p.x, p.y, 14 / this.k) || null
  },

  setHover(node, clientX, clientY) {
    if (this.hover === node) { if (node) this.moveTooltip(clientX, clientY); return }
    this.hover = node
    this.el.style.cursor = node ? "pointer" : "grab"
    if (node) {
      this.tooltip.querySelector("[data-tt-notebook]").textContent = node.notebook || "No notebook"
      this.tooltip.querySelector("[data-tt-title]").textContent = node.title
      this.tooltip.querySelector("[data-tt-dot]").style.background = node.color
      this.tooltip.classList.remove("hidden")
      this.moveTooltip(clientX, clientY)
    } else {
      this.tooltip.classList.add("hidden")
    }
    this.schedule()
  },

  moveTooltip(clientX, clientY) {
    const rect = this.el.getBoundingClientRect()
    const x = clamp(clientX - rect.left + 14, 8, rect.width - 240)
    const y = clamp(clientY - rect.top + 14, 8, rect.height - 70)
    this.tooltip.style.transform = `translate(${x}px, ${y}px)`
  },

  bindInteractions() {
    this.el.addEventListener("wheel", (e) => {
      e.preventDefault()
      this.zoomAt(e.clientX, e.clientY, e.deltaY < 0 ? 1.15 : 0.87)
    }, {passive: false})

    this.el.addEventListener("pointerdown", (e) => {
      if (e.target.closest("[data-ui]")) return
      this.pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})
      if (this.pointers.size === 1) {
        this.moved = 0
        const node = this.hitTest(e.clientX, e.clientY)
        if (node) {
          this.dragNode = node
          this.sim.alphaTarget(0.18).restart()
        }
      }
      this.pinchDist = null
    })

    this.el.addEventListener("pointermove", (e) => {
      if (!this.pointers.has(e.pointerId)) {
        if (!this.dragNode) this.setHover(this.hitTest(e.clientX, e.clientY), e.clientX, e.clientY)
        return
      }
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

      if (this.dragNode) {
        const p = this.toWorld(e.clientX, e.clientY)
        this.dragNode.fx = p.x
        this.dragNode.fy = p.y
        this.setHover(this.dragNode, e.clientX, e.clientY)
        this.schedule()
        return
      }
      if (this.moved > 5) {
        if (!this.el.hasPointerCapture(e.pointerId)) this.el.setPointerCapture(e.pointerId)
        this.el.style.cursor = "grabbing"
        this.tooltip.classList.add("hidden")
        this.tx += dx
        this.ty += dy
        this.schedule()
      }
    })

    const release = (e) => {
      this.pointers.delete(e.pointerId)
      this.pinchDist = null
      if (this.dragNode) {
        if (this.moved <= 5) this.pushEvent("open_note", {id: this.dragNode.id})
        this.dragNode.fx = null
        this.dragNode.fy = null
        this.dragNode = null
        this.sim.alphaTarget(0)
      } else if (this.moved <= 5 && this.pinned) {
        // tapping empty sky releases a search-pinned star
        this.pinned = null
        this.schedule()
      }
      if (this.pointers.size === 0) this.el.style.cursor = this.hover ? "pointer" : "grab"
    }
    this.el.addEventListener("pointerup", release)
    this.el.addEventListener("pointercancel", release)
    this.el.addEventListener("pointerleave", () => { if (!this.dragNode) this.setHover(null) })

    this.el.addEventListener("dblclick", (e) => {
      if (!e.target.closest("[data-ui]")) this.fit()
    })

    this.el.querySelector('[data-zoom="in"]').addEventListener("click", () => this.zoomCenter(1.4))
    this.el.querySelector('[data-zoom="out"]').addEventListener("click", () => this.zoomCenter(0.7))
    this.el.querySelector('[data-zoom="reset"]').addEventListener("click", () => this.fit())

    const simToggle = this.el.querySelector("[data-similarity]")
    simToggle.addEventListener("click", () => {
      this.showSimilarity = !this.showSimilarity
      simToggle.setAttribute("aria-pressed", String(this.showSimilarity))
      simToggle.classList.toggle("ring-1", this.showSimilarity)
      this.schedule()
    })
  },
}
