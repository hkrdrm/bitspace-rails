import { Controller } from "@hotwired/stimulus"

// A live preview beside the admin image filename field. The form works without
// JavaScript -- this only adds the preview.
//
// Sources are handed in by the server as a filename-to-URL map rather than
// assembled here. In production Propshaft precompiles only digested filenames
// and does not mount the middleware that resolves plain ones, so building
// "/assets/<name>" in JavaScript would 404 for every image and the preview
// would silently never appear.
export default class extends Controller {
  static targets = ["input", "preview", "status"]
  static values = { sources: Object }

  connect() {
    this.update()
  }

  update() {
    const filename = this.inputTarget.value.trim()

    if (!filename) {
      this.clear("")
      return
    }

    const source = this.sourcesValue[filename]

    if (!source) {
      this.clear("No file by that name in app/assets/images.")
      return
    }

    this.previewTarget.onerror = () => this.clear("That file could not be loaded.")
    this.previewTarget.onload = () => {
      this.previewTarget.classList.remove("hidden")
      this.setStatus("")
    }
    this.previewTarget.src = source
  }

  clear(message) {
    this.previewTarget.classList.add("hidden")
    this.previewTarget.removeAttribute("src")
    this.setStatus(message)
  }

  setStatus(message) {
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = message
    this.statusTarget.classList.toggle("hidden", message === "")
  }
}
