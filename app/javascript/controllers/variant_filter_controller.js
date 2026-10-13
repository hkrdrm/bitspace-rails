import { Controller } from "@hotwired/stimulus"

// A filter box over a long admin variant table. The server renders the box
// hidden, only when there are more than thirty variants; without JavaScript the
// table is simply complete.
export default class extends Controller {
  static targets = ["query", "row"]

  connect() {
    if (this.hasQueryTarget) this.queryTarget.classList.remove("hidden")
  }

  filter() {
    const query = this.queryTarget.value.trim().toLowerCase()

    this.rowTargets.forEach((row) => {
      row.classList.toggle("hidden", query !== "" && !row.dataset.label.includes(query))
    })
  }
}
