import { Controller } from "@hotwired/stimulus"

// Hides stock columns for colours that are not ticked. The form works without
// this -- every column renders and the server ignores unticked colours -- so
// this only reduces noise.
export default class extends Controller {
  static targets = ["column", "colorToggle"]

  connect() {
    this.refresh()
  }

  refresh() {
    const selected = new Set(
      this.colorToggleTargets.filter((input) => input.checked).map((input) => input.value)
    )

    this.columnTargets.forEach((cell) => {
      cell.classList.toggle("hidden", !selected.has(cell.dataset.color))
    })
  }
}
