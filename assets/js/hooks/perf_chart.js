import embed from "vega-embed"

const mutedColor = "rgba(219, 231, 243, 0.62)"
const gridColor = "rgba(219, 231, 243, 0.10)"

const colorRanges = {
  volume: {
    domain: ["Requests", "Errors", "Fallbacks"],
    range: ["#38bdf8", "#fb7185", "#f59e0b"],
  },
  latency: {
    domain: ["p50", "p95"],
    range: ["#34d399", "#f59e0b"],
  },
}

const seriesValues = (data, fields) =>
  (data.categories || []).flatMap((label, index) =>
    fields.map(([series, key]) => ({
      label,
      index,
      series,
      value: (data[key] || [])[index],
    }))
  )

const valuesFor = (kind, data) => {
  if (kind === "latency") {
    return seriesValues(data, [
      ["p50", "p50_latency_ms"],
      ["p95", "p95_latency_ms"],
    ])
  }

  return seriesValues(data, [
    ["Requests", "requests"],
    ["Errors", "errors"],
    ["Fallbacks", "fallbacks"],
  ])
}

const axisStyle = {
  labelColor: mutedColor,
  titleColor: mutedColor,
  domainColor: gridColor,
  gridColor,
  tickColor: gridColor,
  labelFontSize: 11,
  titleFontSize: 11,
}

const specFor = (kind, data) => {
  const isLatency = kind === "latency"
  const colors = isLatency ? colorRanges.latency : colorRanges.volume

  return {
    $schema: "https://vega.github.io/schema/vega-lite/v6.json",
    width: "container",
    height: 240,
    background: null,
    autosize: {type: "fit", contains: "padding"},
    config: {
      font: "inherit",
      axis: axisStyle,
      legend: {
        labelColor: mutedColor,
        titleColor: mutedColor,
        labelFontSize: 12,
        orient: "bottom",
        direction: "horizontal",
        symbolStrokeWidth: 0,
      },
      view: {stroke: null},
    },
    data: {values: valuesFor(kind, data)},
    mark: {type: "line", interpolate: "monotone", strokeWidth: 2.5},
    encoding: {
      x: {
        field: "label",
        type: "nominal",
        sort: {field: "index"},
        axis: {
          title: null,
          labelAngle: 0,
          labelOverlap: "greedy",
          labelFlush: true,
          tickCount: 6,
        },
      },
      y: {
        field: "value",
        type: "quantitative",
        axis: {
          title: isLatency ? "ms" : null,
          format: "~s",
        },
      },
      color: {
        field: "series",
        type: "nominal",
        scale: colors,
        legend: {title: null},
      },
      order: {field: "index", type: "quantitative"},
      tooltip: [
        {field: "label", title: "Bucket"},
        {field: "series", title: "Series"},
        {field: "value", title: isLatency ? "Latency ms" : "Count", format: ","},
      ],
    },
  }
}

const PerfChart = {
  mounted() {
    this.renderChart()
  },

  updated() {
    this.renderChart()
  },

  destroyed() {
    if (this.view) this.view.finalize()
  },

  async renderChart() {
    const data = JSON.parse(this.el.dataset.chart || "{}")
    const spec = specFor(this.el.dataset.chartKind, data)

    if (this.view) this.view.finalize()

    const result = await embed(this.el, spec, {
      actions: false,
      renderer: "svg",
      theme: "dark",
    })

    this.view = result.view

    const svg = this.el.querySelector("svg")
    if (svg) svg.setAttribute("role", "img")
    if (svg) svg.setAttribute("aria-label", `${this.el.dataset.chartKind || "performance"} chart`)
  },
}

export default PerfChart
