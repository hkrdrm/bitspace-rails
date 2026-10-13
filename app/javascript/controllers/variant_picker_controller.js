import { Controller } from "@hotwired/stimulus"

// The product page's option picker. The server renders a full variant list
// that works without JavaScript; this hides it and shows one button group per
// option instead. Prices and stock come from the variants value, rendered by
// the server, so nothing here formats money or reads availability from markup.
export default class extends Controller {
  static targets = ["list", "picker", "button", "fixed", "price", "status", "image"]
  static values = { variants: Array, images: Object, from: String }

  connect() {
    this.selected = new Map()
    this.fixedTargets.forEach((label) => this.selected.set(label.dataset.optionId, Number(label.dataset.valueId)))
    this.optionIds = [...new Set([...this.fixedTargets, ...this.buttonTargets].map((element) => element.dataset.optionId))]
    this.originalImage = this.hasImageTarget ? this.imageTarget.src : null

    this.listTarget.classList.add("hidden")
    this.pickerTarget.classList.remove("hidden")
    this.render()
  }

  choose(event) {
    const optionId = event.currentTarget.dataset.optionId
    const valueId = Number(event.currentTarget.dataset.valueId)

    if (this.selected.get(optionId) === valueId) {
      this.selected.delete(optionId)
    } else {
      this.selected.set(optionId, valueId)
    }
    this.render()
  }

  render() {
    this.buttonTargets.forEach((button) => {
      const optionId = button.dataset.optionId
      const valueId = Number(button.dataset.valueId)
      const chosen = this.selected.get(optionId) === valueId
      const available = this.variantsValue.some((variant) =>
        variant.stock > 0 && variant.values.includes(valueId) && this.matchesOtherOptions(variant, optionId))

      button.setAttribute("aria-pressed", String(chosen))
      button.classList.toggle("border-brand-green", chosen)
      button.classList.toggle("border-gray-200", !chosen)
      button.classList.toggle("line-through", !available)
      button.classList.toggle("text-gray-400", !available)
      // Strikethrough is invisible to a screen reader, so say it in words too.
      const availability = button.querySelector("[data-availability]")
      if (availability) availability.textContent = available ? "" : " (sold out)"
    })

    const variant = this.selectedVariant()
    this.priceTarget.textContent = variant ? variant.price : this.fromValue
    this.statusTarget.textContent = variant ? (variant.stock > 0 ? "In stock" : "Sold out") : "Choose your options"
    this.showImage()
  }

  matchesOtherOptions(variant, optionId) {
    for (const [otherId, valueId] of this.selected) {
      if (otherId !== optionId && !variant.values.includes(valueId)) return false
    }
    return true
  }

  selectedVariant() {
    if (this.optionIds.some((optionId) => !this.selected.has(optionId))) return null

    const chosen = [...this.selected.values()]
    return this.variantsValue.find((variant) => chosen.every((id) => variant.values.includes(id))) || null
  }

  // The first selected value, in option order, that has its own photo wins.
  showImage() {
    if (!this.hasImageTarget) return

    const withPhoto = this.optionIds.map((optionId) => this.selected.get(optionId)).find((id) => this.imagesValue[id])
    this.imageTarget.src = withPhoto ? this.imagesValue[withPhoto] : this.originalImage
  }
}
