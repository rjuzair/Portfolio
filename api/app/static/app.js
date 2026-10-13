// Flight Reservations — a dependency-free client for the REST API.
// Views are rendered with DOM calls only (no innerHTML with data), so values
// coming from the API can never be interpreted as markup.

const view = document.getElementById("view");
const tooltip = document.getElementById("tooltip");
const toastEl = document.getElementById("toast");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function h(tag, attrs = {}, ...children) {
  const el = document.createElementNS(
    attrs.svg ? "http://www.w3.org/2000/svg" : "http://www.w3.org/1999/xhtml", tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === "svg" || value === undefined || value === null || value === false) continue;
    if (key.startsWith("on")) el.addEventListener(key.slice(2), value);
    else if (key === "class") el.setAttribute("class", value);
    else el.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}
const s = (tag, attrs = {}, ...children) => h(tag, { ...attrs, svg: true }, ...children);

class ApiError extends Error {
  constructor(problem, status) {
    super(problem.detail || `Request failed (${status})`);
    this.status = status;
    this.error = problem.error;
    this.problem = problem;
  }
}

async function api(path, { method = "GET", body } = {}) {
  const response = await fetch(`/api${path}`, {
    method,
    headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (data.errors?.length) {
      data.detail = data.errors.map((e) => `${e.loc.at(-1)}: ${e.msg}`).join("; ");
    }
    throw new ApiError(data, response.status);
  }
  return data;
}

const money = new Intl.NumberFormat("en-IE", { style: "currency", currency: "EUR" });
const moneyCompact = new Intl.NumberFormat("en-IE", {
  style: "currency", currency: "EUR", notation: "compact", maximumFractionDigits: 1,
});
const fmtMoney = (v) => money.format(Number(v));
const fmtDate = (iso) => new Date(`${iso}T00:00:00`).toLocaleDateString("en-GB",
  { weekday: "short", day: "numeric", month: "short", year: "numeric" });
const fmtTime = (t) => t.slice(0, 5);
const isoDate = (d) => d.toISOString().slice(0, 10);
const addDays = (d, n) => new Date(d.getTime() + n * 86400000);

function toast(message) {
  toastEl.textContent = message;
  toastEl.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { toastEl.hidden = true; }, 3500);
}

function errorBox(error) {
  return h("div", { class: "alert error", role: "alert" }, error.message);
}

function loading(label = "Loading…") {
  return h("p", { class: "muted" }, h("span", { class: "spinner", "aria-hidden": "true" }), " ", label);
}

// Runs an async action from a form/button with a busy state and inline error
async function act(button, slot, action) {
  button.disabled = true;
  slot.replaceChildren();
  try {
    await action();
  } catch (error) {
    slot.replaceChildren(errorBox(error));
  } finally {
    button.disabled = false;
  }
}

let airportsCache;
async function airports() {
  airportsCache ??= await api("/airports");
  return airportsCache;
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

const routes = [
  [/^#?\/?$/, searchView, "search"],
  [/^#\/search(\?.*)?$/, searchView, "search"],
  [/^#\/manage$/, manageView, "manage"],
  [/^#\/booking\/([A-Za-z0-9]{6})$/, bookingView, "manage"],
  [/^#\/insights$/, insightsView, "insights"],
];

async function router() {
  const hash = location.hash || "#/";
  const [path] = hash.split("?");
  const query = new URLSearchParams(hash.includes("?") ? hash.slice(hash.indexOf("?") + 1) : "");
  for (const [pattern, render, nav] of routes) {
    const match = path.match(pattern) || hash.match(pattern);
    if (!match) continue;
    document.querySelectorAll("[data-nav]").forEach((a) => {
      if (a.dataset.nav === nav) a.setAttribute("aria-current", "page");
      else a.removeAttribute("aria-current");
    });
    tooltip.hidden = true;
    toastEl.hidden = true;
    view.replaceChildren(loading());
    try {
      await render(view, match, query);
    } catch (error) {
      view.replaceChildren(h("h1", {}, "Something went wrong"), errorBox(error));
    }
    return;
  }
  view.replaceChildren(h("h1", {}, "Page not found"), h("a", { href: "#/" }, "Back to search"));
}

window.addEventListener("hashchange", router);
window.addEventListener("DOMContentLoaded", router);

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

async function searchView(root, _match, query) {
  const list = await airports();
  const today = new Date();
  const params = {
    origin: query.get("origin") ?? "ARN",
    destination: query.get("destination") ?? "",
    date_from: query.get("date_from") ?? isoDate(addDays(today, 1)),
    date_to: query.get("date_to") ?? isoDate(addDays(today, 14)),
    passengers: query.get("passengers") ?? "1",
  };

  const airportSelect = (name, value, anyLabel) => h("select", { id: name, name },
    h("option", { value: "" }, anyLabel),
    list.map((a) => h("option", { value: a.code, selected: a.code === value },
      `${a.code} · ${a.name}`)));

  const form = h("form", { class: "card", role: "search" },
    h("div", { class: "form-grid" },
      h("div", { class: "field" }, h("label", { for: "origin" }, "From"),
        airportSelect("origin", params.origin, "Any airport")),
      h("div", { class: "field" }, h("label", { for: "destination" }, "To"),
        airportSelect("destination", params.destination, "Anywhere")),
      h("div", { class: "field" }, h("label", { for: "date_from" }, "Earliest"),
        h("input", { id: "date_from", name: "date_from", type: "date", value: params.date_from,
                     min: isoDate(today), required: true })),
      h("div", { class: "field" }, h("label", { for: "date_to" }, "Latest"),
        h("input", { id: "date_to", name: "date_to", type: "date", value: params.date_to,
                     min: isoDate(today), required: true })),
      h("div", { class: "field" }, h("label", { for: "passengers" }, "Passengers"),
        h("select", { id: "passengers", name: "passengers" },
          [1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => h("option",
            { value: n, selected: String(n) === params.passengers }, n)))),
      h("button", { class: "btn", type: "submit" }, "Search flights")));

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const data = new URLSearchParams(new FormData(form));
    for (const [key, value] of [...data]) if (!value) data.delete(key);
    location.hash = `#/search?${data}`;
  });

  const results = h("div", { "aria-live": "polite" }, loading("Searching flights…"));
  root.replaceChildren(
    h("div", { class: "hero" },
      h("h1", {}, "Where to next?"),
      h("p", {}, "Fares are set by the database and rise as a flight fills up — ",
        "book early for the best price.")),
    form, results);

  const search = new URLSearchParams(
    Object.fromEntries(Object.entries(params).filter(([, v]) => v)));
  try {
    const flights = await api(`/flights?${search}&limit=60`);
    renderResults(results, flights, Number(params.passengers));
  } catch (error) {
    results.replaceChildren(errorBox(error));
  }
}

function renderResults(root, flights, passengers) {
  if (!flights.length) {
    root.replaceChildren(h("div", { class: "card empty" },
      h("h2", {}, "No flights match"), h("p", {}, "Try other airports or a wider date range.")));
    return;
  }
  const cards = flights.map((f) => {
    const slot = h("div");
    const seats = f.free_seats <= 9
      ? h("span", { class: "badge warn" }, `${f.free_seats} seats left`)
      : h("span", { class: "badge neutral" }, `${f.free_seats} seats left`);
    const button = h("button", { class: "btn", type: "button" }, "Select");
    button.addEventListener("click", () => act(button, slot, async () => {
      const booking = await api("/bookings", {
        method: "POST", body: { flight_id: f.flight_id, passengers } });
      location.hash = `#/booking/${booking.booking_ref}`;
    }));
    return h("article", { class: "flight" },
      h("div", {},
        h("div", { class: "flight-time nums" }, fmtTime(f.departure_time)),
        h("div", { class: "flight-date" }, fmtDate(f.departure_date))),
      h("div", {},
        h("div", { class: "flight-route" }, f.origin.code, h("span", { class: "arrow" }, "→"),
          f.destination.code),
        h("div", { class: "flight-meta" }, `${f.origin.name} to ${f.destination.name}`),
        h("div", { class: "flight-meta" }, f.aircraft_model, " · ", seats)),
      h("div", { class: "flight-price" },
        h("div", { class: "fare nums" }, fmtMoney(f.price_per_seat)),
        h("div", { class: "flight-meta" }, passengers > 1
          ? `${fmtMoney(f.total_price)} for ${passengers}` : "per passenger")),
      h("div", {}, button, slot));
  });
  root.replaceChildren(
    h("p", { class: "muted small", style: "margin-top:16px" },
      `${flights.length} flight${flights.length === 1 ? "" : "s"} found`),
    h("div", { class: "results" }, cards));
}

// ---------------------------------------------------------------------------
// Manage booking
// ---------------------------------------------------------------------------

async function manageView(root) {
  const input = h("input", { id: "ref", name: "ref", required: true, maxlength: 6,
    minlength: 6, pattern: "[A-Za-z0-9]{6}", placeholder: "e.g. K7Q2MX", autocomplete: "off",
    class: "mono", style: "text-transform:uppercase;letter-spacing:.1em" });
  const form = h("form", { class: "card" },
    h("div", { class: "form-grid" },
      h("div", { class: "field" }, h("label", { for: "ref" }, "Booking reference"), input),
      h("button", { class: "btn", type: "submit" }, "Find booking")));
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    location.hash = `#/booking/${input.value.trim().toUpperCase()}`;
  });
  root.replaceChildren(
    h("div", { class: "hero" }, h("h1", {}, "Manage your booking"),
      h("p", {}, "Add passengers, pay, choose seats or cancel — with your six-character reference.")),
    form);
  input.focus();
}

const STEPS = ["Passengers", "Contact", "Payment", "Seats"];

function currentStep(b) {
  if (b.status !== "PENDING") return 4;
  if (b.passengers.length < b.passengers_expected) return 0;
  if (!b.contact) return 1;
  return 2;
}

async function bookingView(root, match) {
  renderBooking(root, await loadBooking(match[1].toUpperCase()));
}

// Fetches the booking plus whatever its current step shows, so each state
// renders in one pass instead of filling in piece by piece
async function loadBooking(ref) {
  const booking = await api(`/bookings/${ref}`);
  const extras = {};
  if (booking.status === "CONFIRMED") {
    [extras.seatMap, extras.quote] = await Promise.all([
      api(`/flights/${booking.flight.flight_id}/seats`),
      api(`/bookings/${ref}/refund-quote`),
    ]);
  } else if (booking.status === "PENDING" && currentStep(booking) === 2) {
    extras.flight = await api(`/flights/${booking.flight.flight_id}`);
  }
  return { booking, extras };
}

function statusBadge(status) {
  const cls = { PENDING: "warn", CONFIRMED: "good", CANCELLED: "critical", EXPIRED: "neutral" };
  return h("span", { class: `badge ${cls[status]}` }, status.toLowerCase());
}

function renderBooking(root, { booking: b, extras }) {
  const step = currentStep(b);
  const refresh = async () => renderBooking(root, await loadBooking(b.booking_ref));
  const f = b.flight;

  const copy = h("button", { class: "btn secondary small", type: "button",
    onclick: async () => {
      await navigator.clipboard?.writeText(b.booking_ref);
      toast("Booking reference copied");
    } }, "Copy");

  const header = h("div", { class: "card" },
    h("div", { class: "booking-head" },
      h("div", {},
        h("div", { class: "muted small" }, "Booking reference"),
        h("div", { class: "row" }, h("span", { class: "ref" }, b.booking_ref), copy,
          statusBadge(b.status))),
      h("div", { style: "text-align:right" },
        h("div", { class: "flight-route" }, f.origin.code, h("span", { class: "arrow" }, " → "),
          f.destination.code),
        h("div", { class: "subtle" }, `${fmtDate(f.departure_date)} · ${fmtTime(f.departure_time)}`),
        h("div", { class: "muted small" }, `${f.origin.name} to ${f.destination.name}`))),
    b.status === "PENDING" || b.status === "CONFIRMED"
      ? h("ol", { class: "stepper", "aria-label": "Booking progress" },
        STEPS.map((name, i) => h("li", {
          class: i < step ? "done" : i === step ? "current" : "",
          "aria-current": i === step ? "step" : undefined },
        h("span", { class: "dot" }, i < step ? "✓" : i + 1), name)))
      : null);

  let body;
  if (b.status === "PENDING") {
    body = [passengersPanel, contactPanel, paymentPanel][step](b, refresh, extras);
  } else if (b.status === "CONFIRMED") {
    body = confirmedPanel(b, refresh, extras);
  } else {
    body = closedPanel(b);
  }
  root.replaceChildren(header, body);
}

function passengerTable(b) {
  if (!b.passengers.length) return h("p", { class: "muted" }, "No passengers yet.");
  return h("div", { class: "table-wrap" }, h("table", {},
    h("thead", {}, h("tr", {}, h("th", {}, "Passenger"), h("th", {}, "Passport"),
      h("th", {}, "Ticket"), h("th", {}, "Seat"))),
    h("tbody", {}, b.passengers.map((p) => h("tr", {},
      h("td", {}, p.name, p.is_contact ? h("span", { class: "muted small" }, " · contact") : null),
      h("td", { class: "mono" }, p.passport),
      h("td", { class: "mono" }, p.ticket ?? "—"),
      h("td", { class: "mono" }, p.seat ?? "—"))))));
}

function passengersPanel(b, refresh) {
  const missing = b.passengers_expected - b.passengers.length;
  const rows = Array.from({ length: missing }, (_, i) => {
    const n = b.passengers.length + i + 1;
    return h("div", { class: "passenger-row" },
      h("div", { class: "field" }, h("label", { for: `name${i}` }, `Passenger ${n} — full name`),
        h("input", { id: `name${i}`, name: `name${i}`, required: true, maxlength: 100,
                     autocomplete: "name" })),
      h("div", { class: "field" }, h("label", { for: `passport${i}` }, "Passport number"),
        h("input", { id: `passport${i}`, name: `passport${i}`, required: true, minlength: 5,
                     maxlength: 20, pattern: "[A-Za-z0-9\\-]+", class: "mono" })));
  });
  const slot = h("div");
  const button = h("button", { class: "btn", type: "submit" }, "Continue");
  const form = h("form", { class: "card" },
    h("h2", {}, "Who is travelling?"),
    h("p", { class: "muted" }, `Seats reserved: ${b.passengers_expected}. `,
      "Unpaid reservations hold no seats and expire after 30 minutes."),
    b.passengers.length ? passengerTable(b) : null, rows, button, slot);
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    act(button, slot, async () => {
      for (let i = 0; i < missing; i++) {
        await api(`/bookings/${b.booking_ref}/passengers`, { method: "POST", body: {
          name: form.elements[`name${i}`].value.trim(),
          passport: form.elements[`passport${i}`].value.trim().toUpperCase() } });
      }
      await refresh();
    });
  });
  return form;
}

function contactPanel(b, refresh) {
  const slot = h("div");
  const button = h("button", { class: "btn", type: "submit" }, "Continue to payment");
  const form = h("form", { class: "card" },
    h("h2", {}, "Contact details"),
    h("p", { class: "muted" }, "One passenger is the contact for the booking."),
    h("div", { class: "form-grid" },
      h("div", { class: "field" }, h("label", { for: "contact" }, "Contact person"),
        h("select", { id: "contact", name: "passport" },
          b.passengers.map((p) => h("option", { value: p.passport }, p.name)))),
      h("div", { class: "field" }, h("label", { for: "email" }, "E-mail"),
        h("input", { id: "email", name: "email", type: "email", required: true,
                     autocomplete: "email" })),
      h("div", { class: "field" }, h("label", { for: "phone" }, "Phone"),
        h("input", { id: "phone", name: "phone", type: "tel", required: true,
                     pattern: "\\+?[0-9][0-9 \\(\\)\\-]{3,19}", autocomplete: "tel",
                     placeholder: "+46 70 123 45 67" }))),
    h("div", { style: "margin-top:16px" }, button), slot);
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    act(button, slot, async () => {
      const data = Object.fromEntries(new FormData(form));
      await api(`/bookings/${b.booking_ref}/contact`, { method: "PUT", body: data });
      await refresh();
    });
  });
  return h("div", { class: "stack" }, form, h("div", { class: "card" }, passengerTable(b)));
}

function paymentPanel(b, refresh, { flight }) {
  const slot = h("div");
  const total = Number(flight.price_per_seat) * b.passengers_expected;
  const summary = h("div", { class: "card summary" },
      h("h2", {}, "Price"),
      h("dl", {},
        h("dt", {}, "Fare per passenger"), h("dd", { class: "nums" }, fmtMoney(flight.price_per_seat)),
        h("dt", {}, "Passengers"), h("dd", { class: "nums" }, b.passengers_expected),
        h("dt", {}, "Total"), h("dd", { class: "total nums" }, fmtMoney(total))),
      h("p", { class: "muted small", style: "margin-top:12px" },
        "You pay the fare at the moment of payment. Seats are re-checked under a lock, ",
        "so the last seats can never be sold twice."));

  const button = h("button", { class: "btn", type: "submit" }, "Pay and issue tickets");
  const form = h("form", { class: "card" },
    h("h2", {}, "Payment"),
    h("div", { class: "form-grid" },
      h("div", { class: "field" }, h("label", { for: "holder" }, "Cardholder"),
        h("input", { id: "holder", name: "cardholder", required: true, maxlength: 100,
                     autocomplete: "cc-name",
                     value: b.passengers.find((p) => p.is_contact)?.name ?? "" })),
      h("div", { class: "field" }, h("label", { for: "card" }, "Card number"),
        h("input", { id: "card", name: "card_number", required: true, inputmode: "numeric",
                     autocomplete: "cc-number", class: "mono",
                     placeholder: "4111 1111 1111 1111" }))),
    h("p", { class: "muted small", style: "margin-top:10px" },
      "Demo: use test card 4111 1111 1111 1111 (Visa) or 5555 5555 5555 4444 (Mastercard). ",
      "Only the brand and last four digits are stored."),
    button, slot);
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    act(button, slot, async () => {
      const data = Object.fromEntries(new FormData(form));
      await api(`/bookings/${b.booking_ref}/payment`, { method: "POST", body: data });
      toast("Payment accepted — tickets issued");
      await refresh();
    });
  });
  return h("div", { class: "grid-2" }, h("div", { class: "stack" }, form,
    h("div", { class: "card" }, passengerTable(b))), summary);
}

function confirmedPanel(b, refresh, { seatMap, quote: q }) {
  const p = b.payment;
  const tickets = h("div", { class: "card" },
    h("div", { class: "row spread" }, h("h2", {}, "Tickets"),
      h("span", { class: "badge good" }, "paid")),
    passengerTable(b));
  const receipt = h("div", { class: "card summary" },
    h("h2", {}, "Payment"),
    h("dl", {},
      h("dt", {}, "Amount"), h("dd", { class: "nums" }, fmtMoney(p.amount)),
      h("dt", {}, "Card"), h("dd", {}, `${p.card_brand} •••• ${p.card_last4}`),
      h("dt", {}, "Paid"), h("dd", {}, new Date(p.paid_at).toLocaleString("en-GB")),
      h("dt", {}, "Contact"), h("dd", {}, b.contact.email)));

  const seats = seatPanel(b, refresh, seatMap);

  const cancelSlot = h("div");
  const pct = Number(q.amount_paid) ? Math.round(100 * q.refund_if_cancelled_now / q.amount_paid) : 0;
  const quote = h("p", { class: "muted" },
    `Cancelling now refunds ${fmtMoney(q.refund_if_cancelled_now)} (${pct} %). `,
    "Policy: 100 % until 30 days before departure, 50 % until 7 days, then nothing.");
  const cancelButton = h("button", { class: "btn danger", type: "button" }, "Cancel booking");
  cancelButton.addEventListener("click", () => {
    if (!confirm(`Cancel booking ${b.booking_ref}? This cannot be undone.`)) return;
    act(cancelButton, cancelSlot, async () => {
      const result = await api(`/bookings/${b.booking_ref}/cancel`, { method: "POST" });
      toast(`Booking cancelled — ${fmtMoney(result.refund)} refunded`);
      await refresh();
    });
  });
  const cancel = h("div", { class: "card" }, h("h2", {}, "Change of plans?"), quote,
    cancelButton, cancelSlot);

  return h("div", { class: "stack" }, h("div", { class: "grid-2" }, tickets, receipt), seats, cancel);
}

function seatPanel(b, refresh, seatMap) {
  let selected = b.passengers.find((p) => !p.seat)?.passport ?? b.passengers[0].passport;
  const slot = h("div");
  const mapHolder = h("div", { class: "seatmap" });
  const picker = h("select", { id: "seat-for", onchange: (e) => { selected = e.target.value; draw(); } },
    b.passengers.map((p) => h("option", { value: p.passport, selected: p.passport === selected },
      `${p.name}${p.seat ? ` (${p.seat})` : ""}`)));

  const ours = new Map(b.passengers.filter((p) => p.seat).map((p) => [p.seat, p]));
  const aisles = seatMap.seats_per_row === 9 ? [3, 6] : [Math.floor(seatMap.seats_per_row / 2)];

  function draw() {
    const current = b.passengers.find((p) => p.passport === selected)?.seat;
    const rows = new Map();
    for (const seat of seatMap.seats) {
      if (!rows.has(seat.row)) rows.set(seat.row, []);
      rows.get(seat.row).push(seat);
    }
    const cabin = h("div", { class: "cabin", role: "grid", "aria-label": "Seat map" },
      [...rows.entries()].map(([row, seats]) => h("div", { class: "cabin-row", role: "row" },
        h("span", { class: "rownum" }, row),
        seats.flatMap((seat, i) => {
          const mine = ours.get(seat.seat_no);
          const taken = seat.taken && !mine;
          const button = h("button", {
            type: "button", role: "gridcell",
            class: `seat${taken ? " taken" : ""}${mine ? " mine" : ""}${seat.seat_no === current ? " current" : ""}`,
            disabled: taken || Boolean(mine),
            title: mine ? `${seat.seat_no} — ${mine.name}` : taken ? `${seat.seat_no} — taken` : seat.seat_no,
            "aria-label": `Seat ${seat.seat_no}, ${mine ? `assigned to ${mine.name}` : taken ? "taken" : "available"}`,
          }, seat.letter);
          if (!taken && !mine) {
            button.addEventListener("click", () => act(button, slot, async () => {
              await api(`/bookings/${b.booking_ref}/passengers/${selected}/seat`,
                { method: "PUT", body: { seat: seat.seat_no } });
              toast(`Seat ${seat.seat_no} confirmed`);
              await refresh();
            }));
          }
          return aisles.includes(i + 1) && i + 1 < seats.length
            ? [button, h("span", { class: "aisle", "aria-hidden": "true" })] : [button];
        }))));
    mapHolder.replaceChildren(cabin);
  }
  draw();

  return h("div", { class: "card" },
    h("div", { class: "row spread" }, h("h2", {}, "Choose seats"),
      h("span", { class: "muted small" }, `${seatMap.aircraft_model} · ${seatMap.seats.length} seats`)),
    h("div", { class: "field", style: "max-width:320px;margin-bottom:12px" },
      h("label", { for: "seat-for" }, "Choosing for"), picker),
    mapHolder,
    h("div", { class: "seat-legend" },
      h("span", {}, h("span", { class: "seat" }), "Available"),
      h("span", {}, h("span", { class: "seat taken" }), "Taken"),
      h("span", {}, h("span", { class: "seat mine" }), "Your party")),
    slot);
}

function closedPanel(b) {
  const p = b.payment;
  return h("div", { class: "stack" },
    h("div", { class: "card" },
      h("h2", {}, b.status === "CANCELLED" ? "This booking was cancelled" : "This booking expired"),
      b.status === "CANCELLED" && p
        ? h("p", {}, `Paid ${fmtMoney(p.amount)}, refunded ${fmtMoney(p.refunded_amount)} `,
          `to ${p.card_brand} •••• ${p.card_last4}.`)
        : h("p", { class: "muted" }, "It was never paid, so no seats were held."),
      h("a", { class: "btn secondary", href: "#/" }, "Search flights")),
    h("div", { class: "card" }, passengerTable(b)));
}

// ---------------------------------------------------------------------------
// Insights
// ---------------------------------------------------------------------------

async function insightsView(root) {
  const [summary, monthly, load, routes] = await Promise.all([
    api("/insights/summary?days=30"),
    api("/insights/monthly-revenue"),
    api("/insights/upcoming-load?days=30"),
    api("/insights/routes"),
  ]);
  const f = summary.funnel;
  const tile = (label, value, note) => h("div", { class: "tile" },
    h("div", { class: "label" }, label), h("div", { class: "value" }, value),
    note ? h("div", { class: "note" }, note) : null);

  const revenueChart = h("div", { class: "chart" });
  const loadChart = h("div", { class: "chart" });

  root.replaceChildren(
    h("div", { class: "hero" }, h("h1", {}, "Insights"),
      h("p", {}, "Live from the analytics views — window functions and CTEs over the same ",
        "tables the booking procedures write to.")),
    h("div", { class: "tiles" },
      tile("Net revenue", moneyCompact.format(summary.net_revenue), "after refunds"),
      tile("Passengers booked", Number(summary.passengers_booked).toLocaleString("en-GB"),
        "on confirmed bookings"),
      tile("Checkout conversion", `${f.conversion_pct ?? 0} %`,
        `${f.paid.toLocaleString("en-GB")} of ${f.reservations.toLocaleString("en-GB")} reservations paid`),
      tile("Load factor, next 30 days",
        summary.upcoming_load_factor_pct === null ? "—" : `${summary.upcoming_load_factor_pct} %`,
        "seats sold / seats flown")),
    h("div", { class: "card" },
      h("h2", {}, "Net revenue by month of travel"),
      h("p", { class: "muted small" }, "Forward bookings: later months fill up as departure nears."),
      revenueChart,
      tableView(["Month", "Bookings", "Passengers", "Net revenue", "Cumulative"],
        monthly.map((m) => [monthLabel(m.travel_month, true), m.paid_bookings, m.passengers,
          fmtMoney(m.net_revenue), fmtMoney(m.cumulative_revenue)]))),
    h("div", { class: "card" },
      h("h2", {}, "Load factor by route, next 30 days"),
      h("p", { class: "muted small" }, "Share of seats sold on flights departing in the next 30 days."),
      loadChart,
      tableView(["Route", "Flights", "Seats sold", "Capacity", "Load factor"],
        load.map((r) => [`${r.departure_airport} → ${r.arrival_airport}`, r.flights,
          r.seats_booked, r.capacity, `${r.load_factor_pct} %`]))),
    h("div", { class: "card" },
      h("h2", {}, `Route league table, ${new Date().getFullYear()}`),
      h("div", { class: "table-wrap" }, h("table", {},
        h("thead", {}, h("tr", {}, ["#", "Route", "Flights", "Seats sold", "Net revenue", "Per seat"]
          .map((c, i) => h("th", { class: i > 1 ? "num" : "" }, c)))),
        h("tbody", {}, routes.map((r) => h("tr", {},
          h("td", { class: "nums" }, r.revenue_rank),
          h("td", {}, `${r.departure_airport} → ${r.arrival_airport}`),
          h("td", { class: "num" }, r.flights),
          h("td", { class: "num" }, r.seats_sold.toLocaleString("en-GB")),
          h("td", { class: "num" }, fmtMoney(r.net_revenue)),
          h("td", { class: "num" }, r.revenue_per_seat ? fmtMoney(r.revenue_per_seat) : "—"))))))));

  const draw = () => {
    columnChart(revenueChart, monthly.map((m) => ({
      label: monthLabel(m.travel_month), title: monthLabel(m.travel_month, true),
      value: Number(m.net_revenue), text: fmtMoney(m.net_revenue),
      detail: `${m.paid_bookings.toLocaleString("en-GB")} bookings` })));
    barChart(loadChart, load.slice(0, 12).map((r) => ({
      label: `${r.departure_airport} → ${r.arrival_airport}`, value: Number(r.load_factor_pct),
      text: `${r.load_factor_pct} %`,
      detail: `${r.seats_booked.toLocaleString("en-GB")} of ${r.capacity.toLocaleString("en-GB")} seats · ${r.flights} flights` })));
  };
  draw();
  const observer = new ResizeObserver(() => draw());
  observer.observe(revenueChart);
  window.addEventListener("hashchange", () => observer.disconnect(), { once: true });
}

function monthLabel(ym, long = false) {
  const [y, m] = ym.split("-").map(Number);
  return new Date(y, m - 1, 1).toLocaleDateString("en-GB",
    long ? { month: "long", year: "numeric" } : { month: "short", year: "2-digit" });
}

function tableView(headers, rows) {
  return h("details", { class: "table-view" }, h("summary", {}, "Show as table"),
    h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, headers.map((c, i) => h("th", { class: i ? "num" : "" }, c)))),
      h("tbody", {}, rows.map((r) => h("tr", {},
        r.map((c, i) => h("td", { class: i ? "num" : "" }, c))))))));
}

function niceStep(value) {
  if (value <= 0) return 1;
  const magnitude = 10 ** Math.floor(Math.log10(value));
  for (const step of [1, 2, 5, 10]) if (step * magnitude >= value) return step * magnitude;
  return 10 * magnitude;
}

function showTip(event, item) {
  tooltip.replaceChildren(h("strong", {}, item.text), h("span", { class: "muted" }, item.title ?? item.label),
    item.detail ? h("span", { class: "muted" }, item.detail) : null);
  tooltip.hidden = false;
  const box = event.target.getBoundingClientRect();
  const x = event.clientX ?? box.left + box.width / 2;
  const y = event.clientY ?? box.top;
  const width = tooltip.offsetWidth;
  tooltip.style.left = `${Math.min(Math.max(8, x + 12), innerWidth - width - 8)}px`;
  tooltip.style.top = `${Math.max(8, y - tooltip.offsetHeight - 12)}px`;
}
const hideTip = () => { tooltip.hidden = true; };

// Path for a bar with a 4px rounded data end and a square baseline end
function barPath(x, y, w, hgt, horizontal) {
  const r = Math.min(4, horizontal ? hgt / 2 : w / 2, horizontal ? w : hgt);
  if (horizontal) {
    return `M${x},${y} H${x + w - r} Q${x + w},${y} ${x + w},${y + r} V${y + hgt - r} ` +
      `Q${x + w},${y + hgt} ${x + w - r},${y + hgt} H${x} Z`;
  }
  return `M${x},${y + hgt} V${y + r} Q${x},${y} ${x + r},${y} H${x + w - r} ` +
    `Q${x + w},${y} ${x + w},${y + r} V${y + hgt} Z`;
}

function columnChart(root, items) {
  if (!items.length) { root.replaceChildren(h("p", { class: "muted" }, "No revenue yet.")); return; }
  const width = Math.max(root.clientWidth, 280);
  const height = 240;
  const pad = { top: 22, right: 8, bottom: 28, left: 56 };
  const plotW = width - pad.left - pad.right;
  const plotH = height - pad.top - pad.bottom;
  const peak = Math.max(...items.map((d) => d.value));
  const step = niceStep(peak / 4);
  const ticks = Math.max(1, Math.ceil(peak / step));
  const max = step * ticks;
  const band = plotW / items.length;
  const barW = Math.min(24, band - 2);
  const y = (v) => pad.top + plotH - (v / max) * plotH;
  const top = items.reduce((a, b) => (b.value > a.value ? b : a));
  const everyNth = Math.ceil(items.length / Math.max(1, Math.floor(plotW / 54)));

  const svg = s("svg", { viewBox: `0 0 ${width} ${height}`, role: "img",
    "aria-label": "Column chart of net revenue by month of travel" });
  for (let i = 0; i <= ticks; i++) {
    const v = step * i;
    svg.append(
      s("line", { class: i ? "grid" : "baseline", x1: pad.left, x2: width - pad.right, y1: y(v), y2: y(v) }),
      s("text", { class: "tick", x: pad.left - 8, y: y(v) + 4, "text-anchor": "end" },
        moneyCompact.format(v)));
  }
  items.forEach((d, i) => {
    const cx = pad.left + band * i + band / 2;
    const barH = Math.max(0, (d.value / max) * plotH);
    const hit = s("rect", { class: "hit", x: pad.left + band * i, y: pad.top, width: band, height: plotH,
      tabindex: 0, "aria-label": `${d.title}: ${d.text}` });
    const mark = s("path", { class: "mark", d: barPath(cx - barW / 2, y(d.value), barW, barH, false) });
    for (const type of ["pointermove", "focus"]) hit.addEventListener(type, (e) => showTip(e, d));
    for (const type of ["pointerleave", "blur"]) hit.addEventListener(type, hideTip);
    svg.append(hit, mark);
    if (i % everyNth === 0) {
      svg.append(s("text", { class: "tick", x: cx, y: height - 8, "text-anchor": "middle" }, d.label));
    }
    if (d === top) {
      svg.append(s("text", { class: "value", x: cx, y: y(d.value) - 7, "text-anchor": "middle" },
        moneyCompact.format(d.value)));
    }
  });
  root.replaceChildren(svg);
}

function barChart(root, items) {
  if (!items.length) { root.replaceChildren(h("p", { class: "muted" }, "No flights in this window.")); return; }
  const width = Math.max(root.clientWidth, 280);
  const rowH = 30;
  const barH = 18;
  const pad = { top: 4, right: 52, bottom: 4, left: 92 };
  const height = pad.top + pad.bottom + rowH * items.length;
  const plotW = width - pad.left - pad.right;
  const x = (v) => (Math.min(v, 100) / 100) * plotW;

  const svg = s("svg", { viewBox: `0 0 ${width} ${height}`, role: "img",
    "aria-label": "Bar chart of load factor by route for the next 30 days" });
  svg.append(s("line", { class: "baseline", x1: pad.left, x2: pad.left, y1: pad.top,
    y2: height - pad.bottom }));
  items.forEach((d, i) => {
    const rowY = pad.top + rowH * i;
    const barY = rowY + (rowH - barH) / 2;
    const hit = s("rect", { class: "hit", x: 0, y: rowY, width, height: rowH, tabindex: 0,
      "aria-label": `${d.label}: ${d.text}` });
    const mark = s("path", { class: "mark", d: barPath(pad.left, barY, Math.max(x(d.value), 1), barH, true) });
    for (const type of ["pointermove", "focus"]) hit.addEventListener(type, (e) => showTip(e, d));
    for (const type of ["pointerleave", "blur"]) hit.addEventListener(type, hideTip);
    svg.append(
      s("text", { class: "label", x: pad.left - 10, y: rowY + rowH / 2 + 4, "text-anchor": "end" }, d.label),
      hit, mark,
      s("text", { class: "value", x: pad.left + x(d.value) + 8, y: rowY + rowH / 2 + 4 }, d.text));
  });
  root.replaceChildren(svg);
}
