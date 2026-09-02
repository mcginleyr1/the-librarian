// Canvas — an infinite board of server-rendered cards. LiveView owns the
// cards; this hook owns what has to be smooth: the pan/zoom transform,
// dragging, resizing, connecting, and the SVG connector layer.
const SVG = "http://www.w3.org/2000/svg"
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi)
const DRAG_THRESHOLD = 5
const MIN_WIDTH = 160
const MIN_HEIGHT = 120
const EDITABLE = "input, textarea, select, [contenteditable], a, button"

export default {
  mounted() {
    this.viewport = this.el.querySelector("[data-viewport]")
    this.edgeLayer = this.el.querySelector("#canvas-edges")
    this.pageId = this.el.dataset.pageId
    this.k = 1; this.tx = 0; this.ty = 0
    this.pointers = new Map()
    this.moved = 0
    this.pinchDist = null
    this.gesture = null
    this.selected = null
    this.resizeObserver = new ResizeObserver(() => this.drawEdges())

    this.restoreView()
    this.applyTransform()
    this.bindPointer()
    this.bindKeys()
    this.bindUi()
    this.observeCards()
    this.drawEdges()
  },

  updated() {
    this.applyTransform()
    this.applySelection()
    this.observeCards()
    this.drawEdges()
  },

  destroyed() {
    window.removeEventListener("keydown", this._keydown)
    this.resizeObserver.disconnect()
  },

  // ---- geometry -------------------------------------------------------------

  toWorld(clientX, clientY) {
    const rect = this.el.getBoundingClientRect()
    return {x: (clientX - rect.left - this.tx) / this.k, y: (clientY - rect.top - this.ty) / this.k}
  },

  cards() {
    return [...this.el.querySelectorAll("[data-node-id]")]
  },

  card(id) {
    return this.el.querySelector(`[data-node-id="${CSS.escape(id)}"]`)
  },

  rect(card) {
    return {x: +card.dataset.x, y: +card.dataset.y, w: card.offsetWidth, h: card.offsetHeight}
  },

  port(rect, side) {
    switch (side) {
      case "top": return {x: rect.x + rect.w / 2, y: rect.y, nx: 0, ny: -1}
      case "bottom": return {x: rect.x + rect.w / 2, y: rect.y + rect.h, nx: 0, ny: 1}
      case "left": return {x: rect.x, y: rect.y + rect.h / 2, nx: -1, ny: 0}
      default: return {x: rect.x + rect.w, y: rect.y + rect.h / 2, nx: 1, ny: 0}
    }
  },

  nearestSide(card, point) {
    const r = this.rect(card)
    let best = "left", bestDist = Infinity
    for (const side of ["top", "right", "bottom", "left"]) {
      const p = this.port(r, side)
      const d = Math.hypot(p.x - point.x, p.y - point.y)
      if (d < bestDist) { best = side; bestDist = d }
    }
    return best
  },

  cardAt(clientX, clientY) {
    return document.elementFromPoint(clientX, clientY)?.closest("[data-node-id]") || null
  },

  // ---- view -----------------------------------------------------------------

  applyTransform() {
    this.viewport.style.transform = `translate(${this.tx}px, ${this.ty}px) scale(${this.k})`
  },

  zoomAt(clientX, clientY, factor) {
    const next = clamp(this.k * factor, 0.2, 3)
    const rect = this.el.getBoundingClientRect()
    const px = clientX - rect.left, py = clientY - rect.top
    this.tx = px - (next / this.k) * (px - this.tx)
    this.ty = py - (next / this.k) * (py - this.ty)
    this.k = next
    this.applyTransform()
    this.saveView()
  },

  fit() {
    const cards = this.cards()
    if (cards.length === 0) { this.k = 1; this.tx = 40; this.ty = 40; this.applyTransform(); return }
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
    for (const c of cards) {
      const r = this.rect(c)
      x0 = Math.min(x0, r.x); y0 = Math.min(y0, r.y)
      x1 = Math.max(x1, r.x + r.w); y1 = Math.max(y1, r.y + r.h)
    }
    const rect = this.el.getBoundingClientRect()
    const k = clamp(Math.min(rect.width / (x1 - x0 + 120), rect.height / (y1 - y0 + 120)), 0.2, 1)
    this.k = k
    this.tx = rect.width / 2 - ((x0 + x1) / 2) * k
    this.ty = rect.height / 2 - ((y0 + y1) / 2) * k
    this.applyTransform()
    this.saveView()
  },

  center() {
    const rect = this.el.getBoundingClientRect()
    return this.toWorld(rect.left + rect.width / 2, rect.top + rect.height / 2)
  },

  saveView() {
    try {
      localStorage.setItem(`canvas:${this.pageId}`, JSON.stringify({k: this.k, tx: this.tx, ty: this.ty}))
    } catch (_e) { /* storage unavailable */ }
  },

  restoreView() {
    try {
      const saved = JSON.parse(localStorage.getItem(`canvas:${this.pageId}`))
      if (saved && Number.isFinite(saved.k)) Object.assign(this, saved)
      else { this.tx = 40; this.ty = 40 }
    } catch (_e) { this.tx = 40; this.ty = 40 }
  },

  // ---- pointer gestures -----------------------------------------------------

  bindPointer() {
    this.el.addEventListener("wheel", (e) => {
      if (e.target.closest("[data-ui]")) return
      e.preventDefault()
      if (e.ctrlKey || e.metaKey) {
        this.zoomAt(e.clientX, e.clientY, e.deltaY < 0 ? 1.1 : 0.9)
      } else {
        this.tx -= e.deltaX
        this.ty -= e.deltaY
        this.applyTransform()
        this.saveView()
      }
    }, {passive: false})

    this.el.addEventListener("pointerdown", (e) => this.onPointerDown(e))
    this.el.addEventListener("pointermove", (e) => this.onPointerMove(e))
    this.el.addEventListener("pointerup", (e) => this.onPointerUp(e))
    this.el.addEventListener("pointercancel", (e) => this.onPointerUp(e))
    this.el.addEventListener("dblclick", (e) => {
      if (!e.target.closest("[data-node-id], [data-ui], [data-edge-id]")) this.fit()
    })
  },

  onPointerDown(e) {
    if (e.pointerType === "mouse" && e.button !== 0) return
    if (e.target.closest("[data-ui]")) return
    this.pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})
    if (this.pointers.size > 1) { this.gesture = null; this.pinchDist = null; return }
    this.moved = 0

    const card = e.target.closest("[data-node-id]")
    const port = e.target.closest("[data-port]")
    const handle = e.target.closest("[data-handle]")?.dataset.handle
    const edge = e.target.closest("[data-edge-id]")

    if (edge) {
      this.select("edge", edge.dataset.edgeId)
      this.gesture = null
    } else if (card && port) {
      this.select("node", card.dataset.nodeId)
      this.gesture = {type: "connect", from: card.dataset.nodeId, fromSide: port.dataset.port, path: this.tempPath()}
    } else if (card && handle === "resize") {
      this.select("node", card.dataset.nodeId)
      this.gesture = {type: "resize", card, w: card.offsetWidth, h: card.offsetHeight, both: card.dataset.resize === "both"}
    } else if (card && (handle === "move" || !e.target.closest(`[data-body], ${EDITABLE}`))) {
      this.select("node", card.dataset.nodeId)
      this.gesture = {type: "move", card, x: +card.dataset.x, y: +card.dataset.y}
    } else if (card) {
      this.select("node", card.dataset.nodeId)
      this.gesture = null
    } else {
      this.gesture = {type: "pan"}
    }
  },

  onPointerMove(e) {
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
    const g = this.gesture
    if (!g || this.moved <= DRAG_THRESHOLD) return
    if (!this.el.hasPointerCapture(e.pointerId)) this.el.setPointerCapture(e.pointerId)

    switch (g.type) {
      case "pan":
        this.tx += dx; this.ty += dy
        this.applyTransform()
        break
      case "move":
        g.x += dx / this.k; g.y += dy / this.k
        g.card.dataset.x = g.x; g.card.dataset.y = g.y
        g.card.style.transform = `translate(${g.x}px, ${g.y}px)`
        this.drawEdges()
        break
      case "resize":
        g.w = Math.max(MIN_WIDTH, g.w + dx / this.k)
        g.card.style.width = `${g.w}px`
        if (g.both) { g.h = Math.max(MIN_HEIGHT, g.h + dy / this.k); g.card.style.height = `${g.h}px` }
        this.drawEdges()
        break
      case "connect":
        this.drawTempEdge(g, this.toWorld(e.clientX, e.clientY))
        break
    }
  },

  onPointerUp(e) {
    this.pointers.delete(e.pointerId)
    this.pinchDist = null
    const g = this.gesture
    if (!g) return
    this.gesture = null
    const click = this.moved <= DRAG_THRESHOLD

    switch (g.type) {
      case "pan":
        if (click) this.clickEmpty(e)
        else this.saveView()
        break
      case "move":
        if (!click) {
          this.pushEvent("move_node", {
            id: g.card.dataset.nodeId, x: Math.round(g.x), y: Math.round(g.y), height: Math.round(g.card.offsetHeight)
          })
        }
        break
      case "resize":
        if (!click) {
          this.pushEvent("resize_node", {
            id: g.card.dataset.nodeId, width: Math.round(g.w), height: Math.round(g.card.offsetHeight)
          })
        }
        break
      case "connect": {
        g.path.remove()
        const target = this.cardAt(e.clientX, e.clientY)
        if (target && target.dataset.nodeId !== g.from) {
          this.pushEvent("add_edge", {
            from: g.from, fromSide: g.fromSide,
            to: target.dataset.nodeId, toSide: this.nearestSide(target, this.toWorld(e.clientX, e.clientY))
          })
        }
        break
      }
    }
  },

  // A click on empty space deselects; a second one starts a text card there.
  clickEmpty(e) {
    if (this.selected || document.activeElement?.matches("textarea, input")) {
      this.select(null)
      document.activeElement?.blur()
      return
    }
    const {x, y} = this.toWorld(e.clientX, e.clientY)
    this.pushEvent("add_text_node", {x: Math.round(x), y: Math.round(y)})
  },

  // ---- selection + keys -----------------------------------------------------

  select(kind, id) {
    this.selected = kind ? {kind, id} : null
    this.applySelection()
  },

  applySelection() {
    for (const c of this.cards()) {
      c.classList.toggle("ring-2", this.selected?.kind === "node" && c.dataset.nodeId === this.selected.id)
      c.classList.toggle("ring-primary/60", this.selected?.kind === "node" && c.dataset.nodeId === this.selected.id)
    }
    for (const p of this.edgeLayer.querySelectorAll("[data-edge-id]")) {
      p.classList.toggle("selected", this.selected?.kind === "edge" && p.dataset.edgeId === this.selected.id)
    }
  },

  bindKeys() {
    this._keydown = (e) => {
      if (e.target.closest("input, textarea, select, [contenteditable]")) return
      if (!this.selected) return
      if (e.key === "Delete" || e.key === "Backspace") {
        e.preventDefault()
        const {kind, id} = this.selected
        this.select(null)
        this.pushEvent(kind === "edge" ? "delete_edge" : "delete_node", {id})
      } else if (e.key === "Escape") {
        this.select(null)
      }
    }
    window.addEventListener("keydown", this._keydown)
  },

  bindUi() {
    this.el.querySelector('[data-zoom="in"]')?.addEventListener("click", () => {
      const r = this.el.getBoundingClientRect()
      this.zoomAt(r.left + r.width / 2, r.top + r.height / 2, 1.25)
    })
    this.el.querySelector('[data-zoom="out"]')?.addEventListener("click", () => {
      const r = this.el.getBoundingClientRect()
      this.zoomAt(r.left + r.width / 2, r.top + r.height / 2, 0.8)
    })
    this.el.querySelector('[data-zoom="fit"]')?.addEventListener("click", () => this.fit())
  },

  observeCards() {
    for (const c of this.cards()) this.resizeObserver.observe(c)
  },

  // ---- connectors -----------------------------------------------------------

  edges() {
    try { return JSON.parse(this.edgeLayer.dataset.edges || "[]") } catch (_e) { return [] }
  },

  edgePath(from, to) {
    const d = Math.max(40, Math.hypot(to.x - from.x, to.y - from.y) / 3)
    return `M ${from.x} ${from.y} C ${from.x + from.nx * d} ${from.y + from.ny * d}, ${to.x + to.nx * d} ${to.y + to.ny * d}, ${to.x} ${to.y}`
  },

  drawEdges() {
    const layer = this.edgeLayer
    layer.replaceChildren(this.defs())
    for (const edge of this.edges()) {
      const a = this.card(edge.fromNode), b = this.card(edge.toNode)
      if (!a || !b) continue
      const from = this.port(this.rect(a), edge.fromSide || this.nearestSide(a, this.centerOf(b)))
      const to = this.port(this.rect(b), edge.toSide || this.nearestSide(b, this.centerOf(a)))
      const d = this.edgePath(from, to)
      const color = edge.color || "currentColor"

      const hit = document.createElementNS(SVG, "path")
      hit.setAttribute("d", d)
      hit.setAttribute("class", "edge-hit")
      hit.dataset.edgeId = edge.id
      hit.classList.toggle("selected", this.selected?.kind === "edge" && this.selected.id === edge.id)
      layer.appendChild(hit)

      const line = document.createElementNS(SVG, "path")
      line.setAttribute("d", d)
      line.setAttribute("class", "edge-line")
      line.setAttribute("stroke", color)
      if (edge.toEnd !== "none") line.setAttribute("marker-end", "url(#canvas-arrow)")
      if (edge.fromEnd === "arrow") line.setAttribute("marker-start", "url(#canvas-arrow-start)")
      layer.appendChild(line)

      if (edge.label) {
        const mid = this.midpoint(from, to)
        const text = document.createElementNS(SVG, "text")
        text.setAttribute("x", mid.x)
        text.setAttribute("y", mid.y)
        text.setAttribute("class", "edge-label")
        text.dataset.edgeId = edge.id
        text.textContent = edge.label
        layer.appendChild(text)
      }
    }
    if (this.gesture?.type === "connect") layer.appendChild(this.gesture.path)
  },

  centerOf(card) {
    const r = this.rect(card)
    return {x: r.x + r.w / 2, y: r.y + r.h / 2}
  },

  midpoint(from, to) {
    const d = Math.max(40, Math.hypot(to.x - from.x, to.y - from.y) / 3)
    const c1 = {x: from.x + from.nx * d, y: from.y + from.ny * d}
    const c2 = {x: to.x + to.nx * d, y: to.y + to.ny * d}
    return {
      x: (from.x + 3 * c1.x + 3 * c2.x + to.x) / 8,
      y: (from.y + 3 * c1.y + 3 * c2.y + to.y) / 8,
    }
  },

  defs() {
    const defs = document.createElementNS(SVG, "defs")
    for (const [id, orient] of [["canvas-arrow", "auto"], ["canvas-arrow-start", "auto-start-reverse"]]) {
      const marker = document.createElementNS(SVG, "marker")
      marker.setAttribute("id", id)
      marker.setAttribute("viewBox", "0 0 10 10")
      marker.setAttribute("refX", "9")
      marker.setAttribute("refY", "5")
      marker.setAttribute("markerWidth", "7")
      marker.setAttribute("markerHeight", "7")
      marker.setAttribute("orient", orient)
      const tip = document.createElementNS(SVG, "path")
      tip.setAttribute("d", "M 0 0 L 10 5 L 0 10 z")
      tip.setAttribute("fill", "context-stroke")
      marker.appendChild(tip)
      defs.appendChild(marker)
    }
    return defs
  },

  tempPath() {
    const p = document.createElementNS(SVG, "path")
    p.setAttribute("class", "edge-line edge-temp")
    p.setAttribute("stroke", "currentColor")
    p.setAttribute("marker-end", "url(#canvas-arrow)")
    this.edgeLayer.appendChild(p)
    return p
  },

  drawTempEdge(g, point) {
    const from = this.port(this.rect(this.card(g.from)), g.fromSide)
    const to = {x: point.x, y: point.y, nx: -from.nx, ny: -from.ny}
    g.path.setAttribute("d", this.edgePath(from, to))
  },
}
