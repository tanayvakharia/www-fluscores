enumerate = (x) -> _.zip([0...x.length], x)
getTime = () -> new Date() * 1e-3

textMesh = (text, style) ->
  mesh = new PIXI.Text(text, style)
  mesh.anchor.set(0.5, 0.5)
  return mesh

class Point

  @ease: (p) -> (1 - Math.cos(Math.min(1, Math.max(0, p)) * Math.PI)) / 2
  @blend: (a, b, weight) -> (1 - weight) * a + weight * b

  constructor: (@mesh, loc) ->
    [@src, @dst] = [loc, loc]

  setTarget: (target, p=1) ->
    weight = Point.ease(p)
    x = Point.blend(@src.x, @dst.x, weight)
    y = Point.blend(@src.y, @dst.y, weight)
    [@src, @dst] = [new PIXI.Point(x, y), target]

  update: (p, w, h) ->
    weight = Point.ease(p)
    @mesh.position.x = w * Point.blend(@src.x, @dst.x, weight)
    @mesh.position.y = h * Point.blend(@src.y, @dst.y, weight)

class Bar

  constructor: () ->
    [@src, @dst] = [{mean: 0, std: 0}, {mean: 0, std: 0}]

  setTarget: (mean, std, p=1) ->
    weight = Point.ease(p)
    mean0 = Point.blend(@src.mean, @dst.mean, weight)
    std0 = Point.blend(@src.std, @dst.std, weight)
    [@src, @dst] = [{mean: mean0, std: std0}, {mean: mean, std: std}]

  draw: (p, plot, color, x, y, w, h) ->
    weight = Point.ease(p)
    mean = Point.blend(@src.mean, @dst.mean, weight)
    std = Point.blend(@src.std, @dst.std, weight)
    barMean = y + plot.getY(mean, p) * h
    barBottom = y + plot.getY(mean - std, p) * h
    barTop = y + plot.getY(mean + std, p) * h
    bar = new PIXI.Graphics()
    bar.lineStyle(0, 0, 0)
    bar.beginFill(color, 0.5)
    bar.drawRect(x - w / 2, barBottom, w, barTop - barBottom)
    bar.endFill()
    bar.lineStyle(3, color, 1)
    bar.moveTo(x - w / 2, barMean)
    bar.lineTo(x + w / 2, barMean)
    if bar.currentPath?.shape
      bar.currentPath.shape.closed = false
    return bar

(exports ? window).FS_Plot = class FS_Plot

  # defaults
  @animationDuration = 0.25
  @colors = [0x4080c0, 0xc04080, 0xc08040, 0x40c080, 0x8040c0, 0x80c040]
  @labelStyle = { font: 'bold 32px Calibri' }
  @tickStyle = { font: '16px Calibri' }

  constructor: (canvas, @teams) ->
    # xTicks, requires FS_Data to be initialized
    @xTicks = (((i + 0.5) / FS_Data.epiweeks.length) for i in [0...FS_Data.epiweeks.length])
    # renderer setup
    [@w, @h] = [canvas.width(), canvas.height()]
    options =
      view: canvas[0]
      antialias: true
    @renderer = new PIXI.autoDetectRenderer(@w, @h, options)
    @renderer.backgroundColor = 0xffffff
    # coloring
    @teamColors = {}
    for [i, team] in enumerate(@teams)
      @teamColors[team] = FS_Plot.colors[i % FS_Plot.colors.length]
    # point for each epiweek for each team
    @showPoints = false
    @stageTeamPoints = {}
    point0 = new PIXI.Point(0.5, 0.5)
    @points = {}
    for team in @teams
      @points[team] = []
      @stageTeamPoints[team] = new PIXI.Container()
      for ew in FS_Data.epiweeks
        graphics = new PIXI.Graphics()
        graphics.beginFill(@teamColors[team], 1)
        graphics.lineStyle(2, 0x000000, 1)
        graphics.drawCircle(0, 0, 4)
        #graphics.drawRect(-4, -4, 8, 8)
        graphics.endFill()
        @stageTeamPoints[team].addChild(graphics)
        @points[team].push(new Point(graphics, point0))
    # order in which lines are drawn
    @lineOrder = [0...@teams.length]
    # bar for each team
    @teamBars = []
    for team in @teams
      @teamBars.push(new Bar())
    # plot initial values
    @renderRequested = false
    @lastMode = @mode = 'line'
    [@plotMin, @plotMax] = [-1, +1]
    # axis stuff
    [@dataMin, @dataMax] = [-1, +1]
    [@axisMin, @axisMax] = [-1.1, +1.1]
    y_label = textMesh('AE/LS', FS_Plot.labelStyle)
    @axisLabels =
      line:
        x: textMesh('Epiweek', FS_Plot.labelStyle)
        y: y_label
      bar:
        x: textMesh('Team', FS_Plot.labelStyle)
        y: y_label
    @axisTicks =
      line:
        x: (textMesh('' + ew, FS_Plot.tickStyle) for ew in FS_Data.epiweeks)
      bar:
        x: (textMesh(team, FS_Plot.tickStyle) for team in @teams)
    # legend
    @legend = new PIXI.Container()
    for [i, team] in enumerate(@teams)
      style =
        font: FS_Plot.tickStyle.font
        fill: @teamColors[team]
      mesh = textMesh(team, style)
      mesh.position.set(mesh.width / 2, 16 * (i + 1))
      @legend.addChild(mesh)
    # wILI overlay
    @wILI = null
    # timing
    @animationStartTime = getTime()

  requestRender: () ->
    if @renderRequested
      return
    @renderRequested = true
    requestAnimationFrame((renderTime) => @render(renderTime))

  render: (renderTime) ->
    @renderRequested = false
    # queue next frame
    animationProgress = (getTime() - @animationStartTime) / FS_Plot.animationDuration
    if animationProgress < 1
      @requestRender()
    # various sections of the screen
    yBox =
      x: 0
      y: 0
      w: 64
      h: @h
    plotBox =
      x: yBox.w
      y: 0
      w: @w - yBox.w
      h: @h - 32
    xBox =
      x: plotBox.x
      y: plotBox.y + plotBox.h
      w: @w - plotBox.x
      h: @h - (plotBox.y + plotBox.h)
    stagePlot = new PIXI.Container()
    stagePlot.position.set(plotBox.x, plotBox.y)
    # wILI overlay
    if @wILI != null and @wILI.length > 0
      line = new PIXI.Graphics()
      line.lineStyle(3, 0x000000, 0.25)
      for i in [1...@wILI.length]
        h = i - 1
        x0 = @xTicks[h] * plotBox.w
        x1 = @xTicks[i] * plotBox.w
        y0 = @getY(Point.blend(@dataMin, @dataMax, @wILI[h])) * plotBox.h
        y1 = @getY(Point.blend(@dataMin, @dataMax, @wILI[i])) * plotBox.h
        line.moveTo(x0, y0)
        line.lineTo(x1, y1)
        if line.currentPath?.shape
          line.currentPath.shape.closed = false
      stagePlot.addChild(line)
    # animate points
    for t in @teams
      for p in @points[t]
        p.update(animationProgress, plotBox.w, plotBox.h)
    # lines through points
    stageLines = new PIXI.Container()
    for teamIndex in @lineOrder
      team = @teams[teamIndex]
      line = new PIXI.Graphics()
      alpha = if @showPoints then 0.75 else 1
      line.lineStyle(3, @teamColors[team], alpha)
      pts = @points[team]
      for i in [1...pts.length]
        h = i - 1
        line.moveTo(pts[h].mesh.position.x, pts[h].mesh.position.y)
        line.lineTo(pts[i].mesh.position.x, pts[i].mesh.position.y)
        if line.currentPath?.shape
          line.currentPath.shape.closed = false
      stageLines.addChild(line)
    stagePlot.addChild(stageLines)
    # draw points on top of lines
    if @showPoints
      for teamIndex in @lineOrder
        stagePlot.addChild(@stageTeamPoints[@teams[teamIndex]])
    ## axis labels
    #x_label = @axisLabels[@mode].x
    #x_label.position.set(@w / 2, @h - 24)
    #y_label = @axisLabels[@mode].y
    #y_label.rotation = -Math.PI / 2
    #y_label.position.set(24, @h / 2)
    # axis decoration
    tickLabels = new PIXI.Container()
    axes = new PIXI.Graphics()
    overlay = new PIXI.Graphics()
    axes.lineStyle(3, 0x000000, 1)
    x0 = xBox.x + @xTicks[0] * xBox.w
    x1 = xBox.x + @xTicks[@xTicks.length - 1] * xBox.w
    y0 = plotBox.y + @getY(@dataMin) * plotBox.h
    y1 = plotBox.y + @getY(@dataMax) * plotBox.h
    # axis bars
    axes.moveTo(plotBox.x, y0)
    axes.lineTo(plotBox.x, y1)
    axes.moveTo(x0, xBox.y)
    axes.lineTo(x1, xBox.y)
    if axes.currentPath?.shape
      axes.currentPath.shape.closed = false
    # y ticks and grid lines
    weight = Point.ease(animationProgress)
    dataMin = Point.blend(@lastDataMin, @dataMin, weight)
    dataMax = Point.blend(@lastDataMax, @dataMax, weight)
    interval = 1
    range = dataMax - dataMin
    while interval >= 0.01 and range / interval < 6
      interval *= 0.5
    while interval < 100 and range / interval >= 12
      interval *= 2
    if Math.abs(dataMax) > Math.abs(dataMin)
      [direction, target] = [+1, Math.abs(dataMax)]
    else
      [direction, target] = [-1, Math.abs(dataMin)]
    for i in [0..(range / interval)]
      value = direction * i * interval
      x = plotBox.x
      y = plotBox.y + @getY(value, animationProgress) * plotBox.h
      str = value.toFixed(2)
      while str.indexOf('.') >= 0 and (str.endsWith('0') or str.endsWith('.'))
        str = str.substring(0, str.length - 1)
      tickLabel = textMesh(str, FS_Plot.tickStyle)
      tickLabel.position.set(x - tickLabel.width / 2 - 15, y)
      tickLabels.addChild(tickLabel)
      axes.lineStyle(1, 0x000000, 0.1)
      axes.moveTo(x0, y)
      axes.lineTo(x1, y)
      axes.lineStyle(3, 0x000000, 1)
      axes.moveTo(x, y)
      axes.lineTo(x - 10, y)
    # x ticks and grid lines
    if @mode == 'line'
      for i in [0...FS_Data.epiweeks.length]
        [x, y] = [xBox.x + @xTicks[i] * xBox.w, xBox.y]
        if i % 3 == 0
          lineWidth = 3
          tickLabel = @axisTicks[@mode].x[i]
          tickLabel.position.set(x, y + 20)
          tickLabels.addChild(tickLabel)
        else
          lineWidth = 1
        axes.lineStyle(1, 0x000000, 0.1)
        axes.moveTo(x, y0)
        axes.lineTo(x, y1)
        if axes.currentPath?.shape
          axes.currentPath.shape.closed = false
        axes.lineStyle(lineWidth, 0x000000, 1)
        axes.moveTo(x, y)
        axes.lineTo(x, y + 10)
        if axes.currentPath?.shape
          axes.currentPath.shape.closed = false
    else
      for [i, team] in enumerate(@teams)
        [x, y] = [xBox.x + (i + 0.5) / @teams.length * xBox.w, xBox.y]
        tickLabel = @axisTicks[@mode].x[i]
        tickLabel.position.set(x, y + 20)
        tickLabels.addChild(tickLabel)
        axes.lineStyle(1, 0x000000, 0.1)
        axes.moveTo(x, y0)
        axes.lineTo(x, y1)
        if axes.currentPath?.shape
          axes.currentPath.shape.closed = false
        axes.lineStyle(3, 0x000000, 1)
        axes.moveTo(x, y)
        axes.lineTo(x, y + 10)
        if axes.currentPath?.shape
          axes.currentPath.shape.closed = false
    # bars on top of the points
    if @mode != 'line' or @lastMode != 'line'
      for [i, bar] in enumerate(@teamBars)
        [x, y] = [xBox.x + (i + 0.5) / @teams.length * xBox.w, plotBox.y]
        [w, h] = [0.9 / @teams.length * plotBox.w, plotBox.h]
        color = @teamColors[@teams[i]]
        p = animationProgress
        b = bar.draw(p, this, color, x, y, w, h)
        if @lastMode != @mode
          if @mode == 'line'
            # fade out
            p = 1 - animationProgress
          else
            # fade in
            p = animationProgress
          b.alpha = Point.ease(p)
        else
          # no fade
          bar.alpha = 1
        overlay.addChild(b)
    # legend placement
    @legend.position.set(plotBox.x + plotBox.w - @legend.width - 8, plotBox.y)
    # put it all together
    stageMain = new PIXI.Container()
    #stageMain.addChild(x_label)
    #stageMain.addChild(y_label)
    stageMain.addChild(tickLabels)
    stageMain.addChild(axes)
    stageMain.addChild(stagePlot)
    stageMain.addChild(overlay)
    stageMain.addChild(@legend)
    # draw everything
    @renderer.render(stageMain)

  update: (teamValues) ->
    # auto-adjust plot bounds
    [min, max] = [0, 0]
    @teamAverages = {}
    @teamStds = {}
    for [i, t] in enumerate(@teams)
      sum = 0
      for value in teamValues[t]
        min = Math.min(min, value)
        max = Math.max(max, value)
        sum += value
      @teamAverages[t] = sum / teamValues[t].length
      sum = 0
      for value in teamValues[t]
        sum += (value - @teamAverages[t]) ** 2
      @teamStds[t] = (sum / teamValues[t].length) ** 0.5
      @teamBars[i].setTarget(@teamAverages[t], @teamStds[t])
    padding = (max - min) * 0.05
    [@lastDataMin, @lastDataMax] = [@dataMin, @dataMax]
    [@lastAxisMin, @lastAxisMax] = [@axisMin, @axisMax]
    [@dataMin, @dataMax] = [min, max]
    [@axisMin, @axisMax] = [min - padding, max + padding]
    # set point targets
    animationProgress = (getTime() - @animationStartTime) / FS_Plot.animationDuration
    if @mode == 'line'
      for i in [0...FS_Data.epiweeks.length]
        x = @xTicks[i]
        for t in @teams
          y = @getY(teamValues[t][i])
          @points[t][i].setTarget(new PIXI.Point(x, y), animationProgress)
    else
      for [teamIndex, team] in enumerate(@teams)
        center = (teamIndex + 0.5) / @teams.length
        width = 0.8 / @teams.length
        [left, right] = [center - width / 2, center + width / 2]
        for weekIndex in [0...FS_Data.epiweeks.length]
          x = Point.blend(left, right, weekIndex / (FS_Data.epiweeks.length - 1))
          y = @getY(teamValues[team][weekIndex])
          @points[team][weekIndex].setTarget(new PIXI.Point(x, y), animationProgress)
    # start the animation
    @animationStartTime = getTime()
    @requestRender()

  getY: (value, p=1) ->
    weight = Point.ease(p)
    min = Point.blend(@lastAxisMin, @axisMin, weight)
    max = Point.blend(@lastAxisMax, @axisMax, weight)
    return 1 - (value - min) / (max - min)

  lineMode: () ->
    [@lastMode, @mode] = [@mode, 'line']

  barMode: () ->
    [@lastMode, @mode] = [@mode, 'bar']

  resize: (width, height) ->
    @renderer.resize(width, height)
    [@w, @h] = [width, height]
    @requestRender()

  setPointsVisible: (visible) ->
    @showPoints = visible
    @requestRender()

  shakeItUp: () ->
    rand = () -> (Math.random() * 2 - 1) * 0.01
    @lineOrder = _.shuffle(@lineOrder)
    @lastMode = @mode
    [@lastDataMin, @lastDataMax] = [@dataMin, @dataMax]
    [@lastAxisMin, @lastAxisMax] = [@axisMin, @axisMax]
    for bar in @teamBars
      bar.src = bar.dst
    for i in [0...FS_Data.epiweeks.length]
      for t in @teams
        point = @points[t][i]
        dst = point.dst
        point.src = new PIXI.Point(dst.x + rand(), dst.y + rand())
    # start the animation
    @animationStartTime = getTime()
    @requestRender()

  setWili: (wILI) ->
    @wILI = wILI
    @requestRender()
