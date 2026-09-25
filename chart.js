// Shared chart/formatting helpers for Nhip San Viet + Bo loc Wyckoff (plain JS, no deps).
(function (global) {
  "use strict";

  function fmtNum(n, d) {
    if (d === undefined) d = 2;
    if (n === null || n === undefined || isNaN(n)) return "—";
    return n.toLocaleString("vi-VN", { minimumFractionDigits: d, maximumFractionDigits: d });
  }
  function fmtInt(n) {
    if (n === null || n === undefined || isNaN(n)) return "—";
    return Math.round(n).toLocaleString("vi-VN");
  }
  function fmtDateShort(d) {
    var p = d.split("-"); return p[2] + "/" + p[1];
  }
  function fmtDateFull(d) {
    var p = d.split("-"); return p[2] + "/" + p[1] + "/" + p[0];
  }
  function fmtDateLong(d) {
    var p = d.split("-");
    var days = ["Chủ Nhật", "Thứ Hai", "Thứ Ba", "Thứ Tư", "Thứ Năm", "Thứ Sáu", "Thứ Bảy"];
    var dt = new Date(d + "T00:00:00");
    return days[dt.getDay()] + ", " + p[2] + "/" + p[1] + "/" + p[0];
  }
  function svgEl(name, attrs) {
    var el = document.createElementNS("http://www.w3.org/2000/svg", name);
    for (var k in attrs) el.setAttribute(k, attrs[k]);
    return el;
  }
  function niceTicks(min, max, count) {
    var range = max - min;
    if (range === 0) { return [min]; }
    var step = range / count;
    var ticks = [];
    for (var i = 0; i <= count; i++) ticks.push(min + step * i);
    return ticks;
  }

  var colorCache = {};
  function getComputedColor(varName) {
    if (colorCache[varName]) return colorCache[varName];
    var v = getComputedStyle(document.documentElement).getPropertyValue(varName).trim();
    colorCache[varName] = v;
    return v;
  }

  // ---- single/multi series chart with hover crosshair ----
  // opts.hLines: [{value, color, label}] horizontal reference lines (e.g. support/resistance)
  // opts.markerIndex: index into `dates` to mark with a vertical dashed line + dot
  function drawChart(container, dates, series, opts) {
    opts = opts || {};
    var W = 760, H = opts.height || 260;
    var padL = 54, padR = 14, padT = 14, padB = 26;
    var innerW = W - padL - padR, innerH = H - padT - padB;
    var n = dates.length;

    container.innerHTML = "";
    var svg = svgEl("svg", { "class": "chart", "viewBox": "0 0 " + W + " " + H, "preserveAspectRatio": "none", "role": "img", "aria-label": opts.ariaLabel || "" });

    if (n < 2) {
      container.appendChild(svg);
      return;
    }

    function xPos(i) { return n <= 1 ? padL + innerW / 2 : padL + (innerW * i) / (n - 1); }

    var allVals = [];
    series.forEach(function (s) { s.points.forEach(function (p) { allVals.push(p.v); }); });
    if (opts.hLines) { opts.hLines.forEach(function (hl) { allVals.push(hl.value); }); }
    var minV = Math.min.apply(null, allVals), maxV = Math.max.apply(null, allVals);
    if (minV === maxV) { minV -= 1; maxV += 1; }
    var pad = (maxV - minV) * 0.10;
    minV -= pad; maxV += pad;
    function yPos(v) { return padT + innerH - ((v - minV) / (maxV - minV)) * innerH; }

    var gGrid = svgEl("g");
    var yTicks = niceTicks(minV + pad, maxV - pad, 4);
    yTicks.forEach(function (t) {
      var y = yPos(t);
      gGrid.appendChild(svgEl("line", { "class": "gridline", x1: padL, x2: W - padR, y1: y, y2: y }));
      var lbl = svgEl("text", { "class": "axis-label", x: padL - 8, y: y + 3, "text-anchor": "end" });
      lbl.textContent = fmtInt(t);
      gGrid.appendChild(lbl);
    });
    gGrid.appendChild(svgEl("line", { "class": "baseline", x1: padL, x2: W - padR, y1: padT + innerH, y2: padT + innerH }));
    svg.appendChild(gGrid);

    var gX = svgEl("g");
    var xTickCount = Math.min(5, n);
    for (var ti = 0; ti < xTickCount; ti++) {
      var idx = xTickCount === 1 ? 0 : Math.round(ti * (n - 1) / (xTickCount - 1));
      var x = xPos(idx);
      var lbl2 = svgEl("text", { "class": "axis-label", x: x, y: H - 6, "text-anchor": ti === 0 ? "start" : (ti === xTickCount - 1 ? "end" : "middle") });
      lbl2.textContent = fmtDateShort(dates[idx]);
      gX.appendChild(lbl2);
    }
    svg.appendChild(gX);

    if (opts.hLines) {
      opts.hLines.forEach(function (hl) {
        var y = yPos(hl.value);
        svg.appendChild(svgEl("line", { x1: padL, x2: W - padR, y1: y, y2: y, stroke: hl.color, "stroke-width": 1.5, "stroke-dasharray": "5 4", "vector-effect": "non-scaling-stroke" }));
        var lbl = svgEl("text", { "class": "end-label", x: W - padR - 2, y: y - 4, "text-anchor": "end", fill: hl.color });
        lbl.textContent = hl.label + " " + fmtNum(hl.value);
        svg.appendChild(lbl);
      });
    }

    series.forEach(function (s) {
      var pts = s.points;
      var linePts = pts.map(function (p, i) { return xPos(i) + "," + yPos(p.v); }).join(" L ");
      if (s.area) {
        var areaPts = "M " + xPos(0) + "," + (padT + innerH) + " L " + linePts + " L " + xPos(pts.length - 1) + "," + (padT + innerH) + " Z";
        svg.appendChild(svgEl("path", { d: areaPts, fill: s.wash, stroke: "none" }));
      }
      svg.appendChild(svgEl("path", { d: "M " + linePts, fill: "none", stroke: s.color, "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round", "vector-effect": "non-scaling-stroke" }));

      var lastP = pts[pts.length - 1];
      var lastX = xPos(pts.length - 1), lastY = yPos(lastP.v);
      svg.appendChild(svgEl("circle", { cx: lastX, cy: lastY, r: 5, fill: "var(--surface)" }));
      svg.appendChild(svgEl("circle", { cx: lastX, cy: lastY, r: 3.5, fill: s.color }));
      var endLbl = svgEl("text", { "class": "end-label", x: Math.min(lastX + 6, W - padR - 2), y: lastY - 8, "text-anchor": lastX > W - padR - 40 ? "end" : "start", fill: s.color });
      endLbl.textContent = opts.endFormat ? opts.endFormat(lastP.v) : fmtNum(lastP.v);
      svg.appendChild(endLbl);
    });

    if (opts.markerIndex !== undefined && opts.markerIndex !== null && opts.markerIndex >= 0 && opts.markerIndex < n) {
      var mx = xPos(opts.markerIndex);
      svg.appendChild(svgEl("line", { x1: mx, x2: mx, y1: padT, y2: padT + innerH, stroke: "var(--muted)", "stroke-width": 1.5, "stroke-dasharray": "2 3", "vector-effect": "non-scaling-stroke" }));
      var my = yPos(series[0].points[opts.markerIndex].v);
      svg.appendChild(svgEl("circle", { cx: mx, cy: my, r: 6, fill: "none", stroke: "var(--muted)", "stroke-width": 1.5 }));
    }

    // crosshair + hover dots
    var crosshair = svgEl("line", { "class": "crosshair", x1: 0, x2: 0, y1: padT, y2: padT + innerH });
    svg.appendChild(crosshair);
    var hoverDots = series.map(function (s) {
      var g = svgEl("g", { "class": "hover-dot" });
      g.appendChild(svgEl("circle", { r: 6, fill: "var(--surface)" }));
      var dot = svgEl("circle", { r: 4, fill: s.color });
      g.appendChild(dot);
      svg.appendChild(g);
      return g;
    });

    var overlay = svgEl("rect", { "class": "overlay-rect", x: padL, y: padT, width: innerW, height: innerH, tabindex: "0" });
    svg.appendChild(overlay);
    container.appendChild(svg);

    var tooltip = document.createElement("div");
    tooltip.className = "tooltip";
    container.appendChild(tooltip);

    var curIdx = -1;
    function showIndex(i) {
      i = Math.max(0, Math.min(n - 1, i));
      curIdx = i;
      var x = xPos(i);
      crosshair.setAttribute("x1", x); crosshair.setAttribute("x2", x);
      crosshair.style.opacity = 1;
      var html = '<div class="t-date">' + fmtDateFull(dates[i]) + '</div>';
      series.forEach(function (s, si) {
        var p = s.points[i];
        var y = yPos(p.v);
        hoverDots[si].style.opacity = 1;
        hoverDots[si].setAttribute("transform", "translate(" + x + "," + y + ")");
        html += '<div class="t-row"><span class="t-key" style="background:' + s.color + '"></span><span class="t-name">' + s.label + '</span><span class="t-val">' + (opts.endFormat ? opts.endFormat(p.v) : fmtNum(p.v)) + '</span></div>';
      });
      tooltip.innerHTML = html;
      tooltip.classList.add("show");
      var rect = svg.getBoundingClientRect();
      var px = rect.left + (x / W) * rect.width;
      var py = rect.top + (padT / H) * rect.height;
      var wrapRect = container.getBoundingClientRect();
      tooltip.style.left = Math.max(60, Math.min(rect.width - 60, px - wrapRect.left)) + "px";
      tooltip.style.top = (py - wrapRect.top) + "px";
    }
    function hideAll() {
      crosshair.style.opacity = 0;
      hoverDots.forEach(function (g) { g.style.opacity = 0; });
      tooltip.classList.remove("show");
      curIdx = -1;
    }
    function pointerToIndex(evt) {
      var pt = svg.createSVGPoint();
      pt.x = evt.clientX; pt.y = evt.clientY;
      var ctm = svg.getScreenCTM();
      if (!ctm) return 0;
      var loc = pt.matrixTransform(ctm.inverse());
      var frac = (loc.x - padL) / innerW;
      return Math.round(frac * (n - 1));
    }
    overlay.addEventListener("pointermove", function (e) { showIndex(pointerToIndex(e)); });
    overlay.addEventListener("pointerdown", function (e) { showIndex(pointerToIndex(e)); });
    overlay.addEventListener("pointerleave", hideAll);
    overlay.addEventListener("keydown", function (e) {
      if (e.key === "ArrowRight") { showIndex((curIdx < 0 ? n - 1 : curIdx) + 1); e.preventDefault(); }
      else if (e.key === "ArrowLeft") { showIndex((curIdx < 0 ? n - 1 : curIdx) - 1); e.preventDefault(); }
    });
    overlay.addEventListener("focus", function () { showIndex(n - 1); });
    overlay.addEventListener("blur", hideAll);
  }

  function drawSpark(svg, points, color, wash) {
    var W = 140, H = 40, pad = 3;
    svg.setAttribute("viewBox", "0 0 " + W + " " + H);
    svg.innerHTML = "";
    if (points.length < 2) return;
    var vals = points.map(function (p) { return p.v; });
    var minV = Math.min.apply(null, vals), maxV = Math.max.apply(null, vals);
    if (minV === maxV) { minV -= 1; maxV += 1; }
    function x(i) { return pad + (W - 2 * pad) * i / (points.length - 1); }
    function y(v) { return pad + (H - 2 * pad) * (1 - (v - minV) / (maxV - minV)); }
    var line = points.map(function (p, i) { return x(i) + "," + y(p.v); }).join(" L ");
    var area = "M " + x(0) + "," + (H - pad) + " L " + line + " L " + x(points.length - 1) + "," + (H - pad) + " Z";
    svg.appendChild(svgEl("path", { d: area, fill: wash, stroke: "none" }));
    svg.appendChild(svgEl("path", { d: "M " + line, fill: "none", stroke: color, "stroke-width": 1.75, "stroke-linejoin": "round", "stroke-linecap": "round", "vector-effect": "non-scaling-stroke" }));
    var lastI = points.length - 1;
    svg.appendChild(svgEl("circle", { cx: x(lastI), cy: y(points[lastI].v), r: 2.5, fill: color }));
  }

  global.VNChart = {
    fmtNum: fmtNum, fmtInt: fmtInt, fmtDateShort: fmtDateShort, fmtDateFull: fmtDateFull, fmtDateLong: fmtDateLong,
    svgEl: svgEl, niceTicks: niceTicks, getComputedColor: getComputedColor, drawChart: drawChart, drawSpark: drawSpark
  };
})(window);
