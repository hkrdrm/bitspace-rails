import { Controller } from "@hotwired/stimulus"

// Conveniences for the admin options section. Without JavaScript the form
// renders spare blank rows and option blocks, which the server ignores when
// left empty. With it, the spares start hidden and Add buttons reveal them.
export default class extends Controller {
  static targets = ["spareValue", "spareOption", "addValue", "addOption"]

  connect() {
    this.spareValueTargets.forEach((row) => row.classList.add("hidden"))
    this.spareOptionTargets.forEach((block) => block.classList.add("hidden"))
    this.addValueTargets.forEach((button) => button.classList.remove("hidden"))
    this.refreshAddOption()
  }

  addValue(event) {
    const block = event.currentTarget.closest("[data-option-block]")
    const spare = block.querySelector("[data-value-row].hidden")

    if (spare) {
      this.reveal(spare)
    } else {
      this.reveal(this.cloneValueRow(block))
    }
  }

  addOption() {
    const block = this.spareOptionTargets.find((candidate) => candidate.classList.contains("hidden"))
    if (!block) return

    block.classList.remove("hidden")
    block.querySelector("[data-value-row].hidden")?.classList.remove("hidden")
    block.querySelector("input")?.focus()
    this.refreshAddOption()
  }

  refreshAddOption() {
    if (!this.hasAddOptionTarget) return

    const anyHidden = this.spareOptionTargets.some((block) => block.classList.contains("hidden"))
    this.addOptionTarget.classList.toggle("hidden", !anyHidden)
  }

  // Every spare row is in use: copy the last row under the next free index.
  cloneValueRow(block) {
    const rows = block.querySelectorAll("[data-value-row]")
    const last = rows[rows.length - 1]
    const copy = last.cloneNode(true)

    copy.querySelectorAll("input").forEach((input) => {
      input.name = input.name.replace(/\[values\]\[\d+\]/, `[values][${rows.length}]`)
      input.value = ""
    })
    last.after(copy)
    return copy
  }

  reveal(row) {
    row.classList.remove("hidden")
    row.querySelector("input")?.focus()
  }
}
