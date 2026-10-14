import { Controller } from "@hotwired/stimulus"

// Rewrites a <time> the server rendered in UTC into the viewer's own time
// zone. Without JavaScript the UTC text stays, labelled as UTC.
export default class extends Controller {
  static values = { format: String }

  connect() {
    const date = new Date(this.element.getAttribute("datetime"))
    if (Number.isNaN(date.getTime())) return

    const options = this.formatValue === "date"
      ? { year: "numeric", month: "2-digit", day: "2-digit" }
      : { year: "numeric", month: "2-digit", day: "2-digit", hour: "numeric", minute: "2-digit", timeZoneName: "short" }
    this.element.textContent = new Intl.DateTimeFormat(undefined, options).format(date)
    this.element.title = date.toISOString()
  }
}
