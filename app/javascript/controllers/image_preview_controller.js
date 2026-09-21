import { Controller } from "@hotwired/stimulus"

// A live preview beside the admin image filename field. The form works
// without JavaScript -- this only adds the preview. Requests a filename
// directly from Propshaft's asset server (a plain 404 on a bad name, not an
// app error) and hides the image on load failure so a typo or a missing file
// never shows a broken image.
export default class extends Controller {
  static targets = ["input", "preview"]

  connect() {
    this.update()
  }

  update() {
    const filename = this.inputTarget.value.trim()

    if (!filename) {
      this.hide()
      return
    }

    this.previewTarget.onerror = () => this.hide()
    this.previewTarget.onload = () => this.show()
    this.previewTarget.src = `/assets/${encodeURIComponent(filename)}`
  }

  show() {
    this.previewTarget.classList.remove("hidden")
  }

  hide() {
    this.previewTarget.classList.add("hidden")
  }
}
