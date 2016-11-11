###
  tileshrink - reduce and simplify vector and mbtiles
  by Michael Strassburger <codepoet@cpan.org>

  Downsamples the extent of all layers and simplifies the resulting polylines
###

MBTiles = require 'mbtiles'
Protobuf = require 'node-protobuf'
Promise = require 'bluebird'
split = require 'split'
simplify = require 'simplify-js'
zlib = require 'zlib'
fs = Promise.promisifyAll require 'fs'

module.exports = class Tileshrink
  config:
    path: "./output"
    targetExtent: 512
    precision: 0.5
    maxZoom: 13

  queueSize: 100

  mbtiles: null
  promises: []
  protobuf: null

  pointsBefore: 0
  pointsAfter: 0
  bytesBefore: 0
  bytesAfter: 0

  constructor: ->
    @protobuf = new Protobuf fs.readFileSync "proto/vector_tile.desc"

  shrink: (source) ->
    console.log "[>] starting to shrink"
    @_loadMBTiles source
    .then => @_shrink()

  _shrink: ->
    new Promise (resolve, reject) =>
      stream = @mbtiles
      .createZXYStream batch: @config.queueSize
      .pipe split()

      queueSpots = @config.queueSize
      paused = false

      stream
      .on 'data', (str) =>
        return unless str

        queueSpots--
        if queueSpots < 1 and not paused
          stream.pause()
          paused = true

        [zoom, x, y] = str.split /\//

        if zoom < @config.maxZoom
          @promises.push promise = @_processTile zoom, x, y
          promise.then ->
            queueSpots++
            if paused and queueSpots > 0
              stream.resume()
              paused = false

      .on 'end', =>
        console.log "[+] waiting for workers..."
        Promise
        .all @promises
        .then =>
          console.log "[+] conversion done!"
          console.log "[>] removed #{c = @pointsBefore-@pointsAfter} points (#{Math.round c/@pointsBefore*100}%)"
          console.log "[>] saved #{Math.round (@bytesBefore-@bytesAfter)/@bytesBefore*100}% of storage"
          resolve()

  _loadMBTiles: (source) ->
    new Promise (resolve, reject) =>
      @mbtiles = new MBTiles source, (err, @mbtiles) =>
        if err then reject err
        else resolve()

  _processTile: (z, x, y) ->
    before = after = 0
    original = null

    @_loadTile z, x, y
    .then (buffer) => @_unzipIfNeeded original = buffer
    .then (buffer) => @_decodeTile buffer
    .then (tile) => @_shrinkTile tile
    .then (tile) => @_encodeTile tile
    .then (buffer) => @_gzip buffer
    .then (buffer) =>
      buffer = original if buffer.length > original.length
      @_trackStats z, x, y, original, buffer

      @_storeTile z, x, y, buffer

  _storeTile: (z, x, y, buffer) ->
    Promise
    .resolve ["/#{z}", "/#{z}/#{x}"]
    .mapSeries (folder) => @_createFolder @config.path+folder
    .then =>
      fs.writeFileAsync @config.path+"/#{z}/#{x}/#{y}.pbf", buffer
      true

  _createFolder: (path) ->
    fs
    .mkdirAsync path
    .then -> true
    .catch (e) -> e.code is "EEXIST"

  _loadTile: (z, x, y) ->
    new Promise (resolve, reject) =>
      @mbtiles.getTile z, x, y, (err, tile) ->
        return reject err if err
        resolve tile

  _unzipIfNeeded: (buffer) ->
    new Promise (resolve, reject) =>
      if @_isGzipped buffer
        zlib.gunzip buffer, (err, data) ->
          return reject err if err
          resolve data
      else
        resolve buffer

  _isGzipped: (buffer) ->
    buffer.slice(0,2).indexOf(Buffer.from([0x1f, 0x8b])) is 0

  _gzip: (buffer) ->
    new Promise (resolve, reject) =>
      zlib.gzip buffer, level: 9, (err, buffer) ->
        return reject err if err
        resolve buffer

  _decodeTile: (buffer) ->
    @protobuf.parse buffer, "vector_tile.Tile"

  _encodeTile: (tile) ->
    @protobuf.serialize tile, "vector_tile.Tile"

  _shrinkTile: (tile) ->
    for layer in tile.layers
      scale = layer.extent / @config.targetExtent
      features = []
      for feature in layer.features
        geometry = @_decodeGeometry feature.geometry
        @pointsBefore += line.length for line in geometry

        scaled = @_scaleAndSimplifyGeometry scale, geometry

        if feature.type is "POLYGON"
          continue if scaled[0].length < 3
          lines = @_reducePolygon scaled

        @pointsAfter += line.length for line in scaled

        feature.geometry = @_encodeGeometry feature, scaled
        features.push feature

      layer.features = features
      layer.extent = @config.targetExtent

    tile

  _scaleAndSimplifyGeometry: (scale, lines) ->
    for line, i in lines
      for point in line
        point.x = Math.floor point.x/scale
        point.y = Math.floor point.y/scale

      if line.length > 1
        lines[i] = simplify line, @config.precision, true

    lines

  _reducePolygon: (rings) ->
    reduced = [rings[0]]
    for ring in rings[1..]
      if ring.length > 2
        reduced.push ring
    reduced

  _decodeGeometry: (geometry) ->
    idx = x = y = count = command = line = 0
    lines = []

    while idx < geometry.length
      unless count
        raw = geometry[idx++]
        command = raw & 7
        count = raw >> 3
      count--

      if command is 1 or command is 2
        x += @_dezigzag geometry[idx++]
        y += @_dezigzag geometry[idx++]

        if command is 1
          lines.push line if line
          line = []

        line.push x: x, y: y

      else if command is 7
        line.push x: line[0].x, y: line[0].y

    lines.push line if line
    lines

  _encodeGeometry: (feature, geometry) ->
    x = y = 0
    encoded = []

    for line in geometry
      encoded.push @_command 1, 1

      last = line.length-1
      close =
        feature.type is "POLYGON" and
        line[last].x is line[0].x and
        line[last].y is line[0].y

      for point, i in line
        if i is 1
          encoded.push @_command 2, line.length-(if close then 2 else 1)

        else if close and i is last
          encoded.push @_command 7, 1
          break

        dx = point.x - x
        dy = point.y - y

        encoded.push @_zigzag(dx), @_zigzag(dy)

        x += dx
        y += dy

    encoded

  _command: (command, count) ->
    (command & 7) | (count << 3)

  _zigzag: (int) ->
    (int << 1) ^ (int >> 31)

  _dezigzag: (int) ->
    (int >> 1) ^ -(int & 1)

  _trackStats: (z, x, y, original, reduced) ->
    saved = original.length-reduced.length
    @bytesBefore += original.length
    @bytesAfter += reduced.length
    console.log "[>] #{Math.round saved/original.length*100}% less data in zoom #{z}, x: #{x} y: #{y}"