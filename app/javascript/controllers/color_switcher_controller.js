import { Controller } from "@hotwired/stimulus"

// Shows one colour's size ladder at a time. Without JavaScript every section
// stays visible, which is correct, just longer.
export default class extends Controller {
  static targets = ["section", "button"]

  connect() {
    this.show(this.sectionTargets[0]?.dataset?.color)
  }

  select(event) {
    this.show(event.currentTarget.dataset.color)
  }

  show(color) {
    if (!color) return

    this.sectionTargets.forEach((section) => {
      section.classList.toggle("hidden", section.dataset.color !== color)
    })

    this.buttonTargets.forEach((button) => {
      const active = button.dataset.color === color
      button.classList.toggle("border-brand-green", active)
      button.classList.toggle("border-gray-200", !active)
    })
  }
}
