(exports ? window).FS_Data = class FS_Data

  @regions = ((if i == 0 then 'Nat' else "Reg#{i}") for i in [0..10])
  @hhsRegions = ((if i == 0 then 'nat' else "hhs#{i}") for i in [0..10])
  @targets_seasonal = ['onset', 'peakweek', 'peak']
  @targets_local = ['1_week', '2_week', '3_week', '4_week']
  @targets = @targets_seasonal.concat(@targets_local)
  @errors = ['LS', 'AE']
  @error_labels = ['log score', 'absolute error']
  @wILI = null

  @init = (season) ->
    if @wILI != null
      return
    if season == 2014
      @epiweeks = (('' + if i <= 13 then 201440 + i else 201500 + i - 13) for i in [1..32])
    else if season == 2015
      @epiweeks = (('' + if i <= 12 then 201540 + i else 201600 + i - 12) for i in [2..30])
    else
      throw new Error('unsupported season: ' + season)
    getCallback = (hhs, name) =>
      return (result, message, epidata) =>
        if result != 1
          console.log("Epidata API [fluview, #{hhs}] says: #{message}")
        else
          wili = (row.wili for row in epidata)
          [min, max] = [10, 0]
          for w in wili
            [min, max] = [Math.min(min, w), Math.max(max, w)]
          @wILI[name] = ((w - min) / (max - min) for w in wili)
    @wILI = { combine: [] }
    weekRange = Epidata.range(@epiweeks[0], @epiweeks[@epiweeks.length - 1])
    for [hhs, name] in _.zip(@hhsRegions, @regions)
      @wILI[name] = []
      Epidata.fluview(getCallback(hhs, name), hhs, weekRange)

  @update = (data, error, target, region, epiweek) ->
    totals = null
    if target == 'combine'
      targets = @targets
    else if target == 'seasonal'
      targets = @targets_seasonal
    else if target == 'local'
      targets = @targets_local
    else
      targets = [target]
    regions = if region == 'combine' then @regions else [region]
    nr = regions.length
    nt = targets.length
    teams = (t for t of data)
    for r in regions
      for t in targets
        values = []
        for team in teams
          row = []
          for w in @epiweeks
            v = data[team][r][t][error][w]
            row.push(v / (nr * nt))
          values.push(row)
        if totals == null
          totals = values
        else
          for [src_row, dst_row] in _.zip(values, totals)
            i = 0
            while i < dst_row.length
              dst_row[i] += src_row[i]
              i++
    return totals

  transpose = (arr1) ->
    arr2 = []
    for col in arr1[0]
      arr2.push(Array(arr1.length))
    for r in [0 .. (arr1.length - 1)]
      for c in [0 .. (arr1[0].length - 1)]
        arr2[c][r] = arr1[r][c]
    return arr2

  @addAllOptions = (error, target, region) ->
    combine = { value: 'combine', text: '[average of all]' }
    seasonal = { value: 'seasonal', text: '[3 long-term]' }
    local = { value: 'local', text: '[4 short-term]' }
    addOptions(error, @errors, @error_labels)
    addOptions(target, @targets, @targets, [combine, seasonal, local])
    addOptions(region, @regions, @regions, [combine])

  addOptions = (select, values, labels, custom=[]) ->
    for c in custom
      select.append($('<option/>', { value: c.value, text: c.text }))
    for [value, text] in _.zip(values, labels)
      select.append($('<option/>', { value: value, text: text }))

  @loadFiles: (files, onSuccess, onFailure) ->
    # sanity checks
    if files.length == 0
      return onFailure('no files selected')
    for file in files
      if !file.name.endsWith('.zip')
        return onFailure("#{file.name} is not a zip file")
    # load files one after another
    fileIndex = 0
    data = {}
    callback = (name, fileData, error) ->
      if error?
        return onFailure(error)
      data[name] = fileData
      if fileIndex < files.length
        loadSingle(files[fileIndex++], callback)
      else
        return onSuccess((t for t of data), data)
    loadSingle(files[fileIndex++], callback)

  loadSingle = (file, callback) ->
    reader = new FileReader()
    reader.onload = (event) ->
      zip = new JSZip(event.target.result)
      data = {}
      error = null
      try
        for region in FS_Data.regions
          data[region] = {}
          values = getValues(file.name, zip, region, '')
          unpackValues(data[region], values, FS_Data.targets_seasonal)
          values = getValues(file.name, zip, region, '_4wk')
          unpackValues(data[region], values, FS_Data.targets_local)
      catch ex
        error = ex.message ? '' + ex
      callback(file.name, data, error)
    reader.readAsArrayBuffer(file)

  unpackValues = (data, values, targets) ->
    i = 0
    for target in targets
      data[target] = {}
      for err in FS_Data.errors
        data[target][err] = {}
        for ew in FS_Data.epiweeks
          data[target][err][ew] = values[i++]

  getValues = (filename, zip, region, target) ->
    pattern = "^#{region}#{target}_Team.*\\.csv$"
    regex = new RegExp(pattern)
    for entry of zip.files
      if regex.test(entry)
        text = zip.files[entry].asText()
        return parseCSV(zip.files[entry].asText())
    throw { message: "/#{pattern}/ not in #{filename}" }

  parseCSV = (csv) ->
    fields = csv.split('\n')[1].split(',')
    fields.shift()
    fix = (n) -> if Number.isNaN(n) then -10 else n
    return (fix(parseFloat(f)) for f in fields)
