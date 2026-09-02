// WikilinkComplete — `[[` autocomplete for a textarea. The menu element is
// named by data-menu (default "wikilink-menu") and is owned by this hook.
export default {
  mounted() {
    this.menu = document.getElementById(this.el.dataset.menu || "wikilink-menu")
    this.items = []
    this.index = 0
    this.open = false

    this.el.addEventListener("input", () => this.check())
    this.el.addEventListener("blur", () => setTimeout(() => this.close(), 150))
    this.el.addEventListener("keydown", (e) => {
      if (!this.open) return
      if (e.key === "ArrowDown") { e.preventDefault(); this.move(1) }
      else if (e.key === "ArrowUp") { e.preventDefault(); this.move(-1) }
      else if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); this.accept(this.items[this.index]) }
      else if (e.key === "Escape") { e.stopPropagation(); this.close() }
    })
  },
  destroyed() { this.close() },
  check() {
    const match = this.partial()
    if (!match) return this.close()
    this.pushEvent("wikilink_suggest", {q: match[1]}, ({suggestions}) => {
      if (!suggestions || suggestions.length === 0) return this.close()
      this.items = suggestions
      this.index = 0
      this.render()
    })
  },
  partial() {
    const upToCaret = this.el.value.slice(0, this.el.selectionStart)
    return upToCaret.match(/\[\[([^\]\n]*)$/)
  },
  render() {
    this.open = true
    this.menu.classList.remove("hidden")
    this.menu.innerHTML = ""
    this.items.forEach((item, i) => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.textContent = item.title
      btn.className = "block w-full text-left px-3 py-1.5 text-sm truncate rounded-md" +
        (i === this.index ? " bg-primary/10 text-primary" : "")
      btn.addEventListener("mousedown", (e) => { e.preventDefault(); this.accept(item) })
      this.menu.appendChild(btn)
    })
  },
  move(delta) {
    this.index = Math.min(Math.max(this.index + delta, 0), this.items.length - 1)
    this.render()
  },
  accept(item) {
    if (!item) return
    const match = this.partial()
    if (!match) return this.close()
    const pos = this.el.selectionStart
    const start = pos - match[1].length
    const rest = this.el.value.slice(pos)
    const closing = rest.startsWith("]]") ? "" : "]]"
    this.el.value = this.el.value.slice(0, start) + item.title + closing + rest
    const caret = start + item.title.length + 2
    this.el.setSelectionRange(caret, caret)
    this.el.dispatchEvent(new Event("input", {bubbles: true}))
    this.el.focus()
  },
  close() {
    this.open = false
    this.items = []
    if (this.menu) {
      this.menu.classList.add("hidden")
      this.menu.innerHTML = ""
    }
  }
}
