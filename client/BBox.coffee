## Axis-Aligned Bounding Box

## Chrome seems to truncate SVG rects and ellipses to zero and not render
## (or incorrectly render) when their width or height is less than 0.000001.
## But if both width and height are small, rects need to be at least 0.0001
## and ellipses need to be at least 0.1 in diameter (0.05 in radius).
export minSvgSize = 0.1

export class BBox
  constructor: (@minX, @minY, @maxX, @maxY) ->

  @fromPoint: (pt) ->
    new BBox pt.x, pt.y, pt.x, pt.y
  @fromExtremePoints: (min, max) ->  # assumes min and max are in order
    new BBox min.x, min.y, max.x, max.y
  @fromPoints: (pts) ->
    minX = minY = Infinity
    maxX = maxY = -Infinity
    for {x, y} in pts
      minX = x if x < minX
      maxX = x if x > maxX
      minY = y if y < minY
      maxY = y if y > maxY
    new BBox minX, minY, maxX, maxY
  @fromRect: (rect) ->
    new BBox rect.x, rect.y, rect.x + rect.width, rect.y + rect.height

  center: ->
    x: (@maxX + @minX) / 2
    y: (@maxY + @minY) / 2
  width: -> @maxX - @minX
  height: -> @maxY - @minY
  toRect: ->
    x: @minX
    y: @minY
    width: @width()
    height: @height()
  ## Guarantee toRect has width and height at least epsilon
  minSize: (epsilon = minSvgSize) ->
    new BBox @minX, @minY,
      (if @width() < epsilon then @maxX + epsilon else @maxX),
      (if @height() < epsilon then @maxY + epsilon else @maxY)

  translate: (dx, dy) ->
    new BBox @minX + dx, @minY + dy, @maxX + dx, @maxY + dy
  fattened: (fat) ->
    new BBox @minX - fat, @minY - fat, @maxX + fat, @maxY + fat
  fattenedXY: (fatX, fatY) ->
    new BBox @minX - fatX, @minY - fatY, @maxX + fatX, @maxY + fatY

  area: -> @width() * @height()

  perimeter: -> 2 * (@width() + @height())

  cost: -> @perimeter()

  intersects: (other) ->
    @minX <= other.maxX and @maxX >= other.minX and @minY <= other.maxY and @maxY >= other.minY

  contains: (other) ->
    @minX <= other.minX and @maxX >= other.maxX and @minY <= other.minY and @maxY >= other.maxY

  # Point must have an x field and a y field
  containsPoint: (pt) ->
    @minX <= pt.x and @maxX >= pt.x and @minY <= pt.y and @maxY >= pt.y

  union: (other) ->
    new BBox (Math.min @minX, other.minX), (Math.min @minY, other.minY),
             (Math.max @maxX, other.maxX), (Math.max @maxY, other.maxY)
  @union: (bboxes) ->
    minX = minY = Infinity
    maxX = maxY = -Infinity
    for bbox in bboxes
      minX = bbox.minX if bbox.minX < minX
      maxX = bbox.maxX if bbox.maxX > maxX
      minY = bbox.minY if bbox.minY < minY
      maxY = bbox.maxY if bbox.maxY > maxY
    if minX == Infinity
      new BBox 0, 0, 0, 0
    else
      new BBox minX, minY, maxX, maxY

  eq: (other) ->
    @minX == other.minX and @maxX == other.maxX and
    @minY == other.minY and @maxY == other.maxY
