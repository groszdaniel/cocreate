import {onCleanup} from 'solid-js'
import debounce from 'debounce'

import {defineTool} from './defineTool'
import {tryAddImageUrl} from './image'
import {tools, selectTool} from './tools'
import {anchorFromEvent, anchorMove, anchorsOf, rawAnchorsOf} from '../Anchor'
import {currentBoard, mainBoard, currentRoom, currentPage, currentTool, currentArrowStart, currentArrowEnd, currentColor, currentDash, currentFill, currentFillOn, currentFontSize, currentOpacity, currentOpacityOn, currentWidth} from '../AppState'
import {maybeSnapPointToGrid} from '../Grid'
import {Highlighter, highlighterClear} from '../Selection'
import {undoStack} from '../UndoStack'
import dom from '../lib/dom'
import {average, centroid, distance, distanceThreshold} from '../lib/geom'
import {Ctrl, Alt} from '../lib/platform'
import throttle from '../lib/throttle'
import {BBox, minSvgSize} from '../BBox'
import {intersects} from '../Collision'

export pointers = {}   # maps pointerId to tool-specific data

# Require movement by this many client pixels...
eraseDist = 4   # ...before erasing swipe
dragDist = 4    # ...before select drags
dotDist = 4     # ...before rect/ellipse leave dot mode
doubleClickDist = 4    # ...max dist between clicks in double click
doubleClickTime = 1000 # ...msec between between clicks in double click

eventDistanceThreshold = (p, q, t) ->
  return false if not p or not q
  return true if p == true or q == true
  dx = p.clientX - q.clientX
  dy = p.clientY - q.clientY
  dx * dx + dy * dy >= t * t

defineTool
  name: 'pan'
  category: 'mode'
  icon: 'arrows-alt'
  hotspot: [0.5, 0.5]
  help: 'Pan around the page by dragging. Two-finger pinch to zoom.'
  hotkey: 'hold SPACE or middle mouse button'
  start: ->
    pointers.transform = null  # triggers refresh
  down: (e) ->
    point = currentBoard().eventToRawPoint e
    pointers[e.pointerId] =
      start: point
      now: point
    @refresh()
  up: (e) ->
    delete pointers[e.pointerId]
    @refresh()
  refresh: ->
    ## Start new pan/zoom operation whenever number of pointers changes.
    for key, value of pointers
      if key == 'transform'
        pointers.transform = {...currentBoard().transform}
      else
        pointers[key].start = value.now
  move: (e) ->
    return unless (pointer = pointers[e.pointerId])?
    board = currentBoard()
    pointer.now = board.eventToRawPoint e
    pointerList = (p for key, p of pointers when key != 'transform')
    if pointerList.length == 1
      board.setTransform
        x: pointers.transform.x +
           (pointer.now.x - pointer.start.x) / pointers.transform.scale
        y: pointers.transform.y +
           (pointer.now.y - pointer.start.y) / pointers.transform.scale
    else
      midStart = centroid (p.start for p in pointerList)
      distStart = average (distance p.start, midStart for p in pointerList)
      midNow = centroid (p.now for p in pointerList)
      distNow = average (distance p.now, midNow for p in pointerList)
      newScale = pointers.transform.scale * distNow / distStart
      # Code below is similar in spirit to Board::setScaleFixingPoint
      board.setTransform
        scale: newScale
        x: pointers.transform.x +
           midNow.x / newScale - midStart.x / pointers.transform.scale
        y: pointers.transform.y +
           midNow.y / newScale - midStart.y / pointers.transform.scale

## Virtual tool sent touch events (only) directly by DrawApp
## when the event wouldn't be sent to the actual tool.
defineTool
  name: 'multitouch'
  category: 'hidden'
  pointers: {}
  down: (e) ->
    point = currentBoard().eventToRawPoint e
    @pointers[e.pointerId] =
      start: point
      now: point
    @refresh()
  up: (e) ->
    delete @pointers[e.pointerId]
    @refresh()
  refresh: ->
    ## Start new pan/zoom operation whenever number of pointers changes.
    for key, value of @pointers
      @pointers[key].start = value.now
    @transform = {...currentBoard().transform}
  move: (e) ->
    return unless (pointer = @pointers[e.pointerId])?
    board = currentBoard()
    pointer.now = board.eventToRawPoint e
    pointerList = (p for key, p of @pointers)
    return if pointerList.length == 1
    midStart = centroid (p.start for p in pointerList)
    distStart = average (distance p.start, midStart for p in pointerList)
    midNow = centroid (p.now for p in pointerList)
    distNow = average (distance p.now, midNow for p in pointerList)
    newScale = @transform.scale * distNow / distStart
    # Code below is similar in spirit to Board::setScaleFixingPoint
    board.setTransform
      scale: newScale
      x: @transform.x + midNow.x / newScale - midStart.x / @transform.scale
      y: @transform.y + midNow.y / newScale - midStart.y / @transform.scale

defineTool
  name: 'select'
  category: 'mode'
  icon: 'mouse-pointer'
  hotspot: [0.21875, 0.03515625]
  help: <>Select objects by dragging rectangle or clicking on individual objects (toggling multiple if holding <kbd>Shift</kbd>). Then change their color/width, move by dragging (<kbd>Shift</kbd> for horizontal/vertical) or using arrow keys (<kbd>Shift</kbd> for half-grid), copy via <kbd>{Ctrl}-C</kbd>, cut via <kbd>{Ctrl}-X</kbd>, paste via <kbd>{Ctrl}-V</kbd>, duplicate via <kbd>{Ctrl}-D</kbd>, or <kbd>Delete</kbd> them.</>
  hotkey: 's'
  start: ->
    pointers.objects = {}
    pointers.firstClick = {}
  stop: ->
    delete pointers.objects
    delete pointers.firstClick
  down: (e) ->
    selection = currentBoard().selection
    pointers[e.pointerId] ?= new Highlighter currentBoard()
    h = pointers[e.pointerId]
    return if h.down  # in case of repeat events
    h.down = e
    h.start = currentBoard().eventToPoint e
    h.moved = null
    h.edit = throttle.func (diffs) ->
      Meteor.call 'objectsEdit', (diff for id, diff of diffs)
    , ([older], [newer]) ->
      [Object.assign older, newer]
    ## Check for clicking on a selected object, to ensure dragging selection
    ## works even when another object is more topmost.
    ## Also check for clicking within the selection outline.
    {selected, outline} = h.eventSelected e, selection
    if selected.length
      h.highlight selected[0]
    ## Deselect existing selection unless requesting multiselect
    toggle = e.shiftKey or e.ctrlKey or e.metaKey
    unless toggle or outline? or selection.has h.id
      selection.clear()
    ## Refresh previously selected objects, in particular so tx/ty up-to-date
    pointers.objects = {}
    for id in selection.ids()
      pointers.objects[id] = Objects.findOne id
    unless h.id?  # see if we pressed on something
      target = h.eventTop e
      if target?
        h.highlight target
    ## If we clicked on an object or within the selection outline,
    ## then we update the selection and prepare for dragging it,
    ## except that selection outline doesn't count when we
    ## shift/ctrl/meta-click (toggle)
    if h.id? or (outline? and not toggle)
      ## Potential start of dragging to move objects.  h.start already set.
      ## Previously we snapped the start point to the grid, but it's more
      ## accurate to snap the vector between the start and end points.
      #h.start = maybeSnapPointToGrid h.start  # don't snap selection rectangle
      unless outline? and not toggle
        ## In this case, we must have something highlighted, in h.id,
        ## and we're either toggling or not dragging the selection outline.
        unless selection.has h.id
          pointers.objects[h.id] = Objects.findOne h.id
          selection.add h
          selection.setAttributes() if selection.count() == 1
        else if toggle
          selection.remove h.id
          delete pointers.objects[h.id]
          ## Prevent dragging after deselecting an object
          h.start = null
        h.clear()  # avoid leftover shadow when dragging
    ## If we click on blank space, or shift/ctrl/meta-click within the
    ## selection rectangle, then we draw a selection rectangle.
    else
      h.selectorStart h.start
  up: (e) ->
    h = pointers[e.pointerId]
    if h?.selector?  # finished rectangular drag
      board = currentBoard()
      {render, selection} = board
      query = BBox.fromPoints [h.start, board.eventToPoint e]
      # render is undefined when history mode starts but hasn't been advanced
      for id of render?.dom ? {}
      #for id from render.dbvt.query query
        bbox = render.bbox[id]
        continue unless query.intersects bbox  # quick filter
        obj = board.findObject id
        continue unless obj?
        if intersects query, obj, bbox
          if selection.has id  # Toggle selection
            selection.remove id
          else
            h.highlight render.dom[id]
            selection.add h
      selection.setAttributes()
      h.selectorClear()
    else if h?.moved  # finished dragging objects
      h.edit.flush()
      undoStack.push
        type: 'multi'
        ops:
          for id, obj of pointers.objects when obj?
            type: 'edit'
            id: id
            before:
              tx: obj.tx ? 0
              ty: obj.ty ? 0
            after: h.moved[id]
    else if h?.down != true  # finished regular click without drag
      objects = (id for id of pointers.objects)
      if objects.length == 1  # clicked on an object
        if (firstClick = pointers.firstClick[e.pointerId])? and
           firstClick.id == objects[0] and
           not eventDistanceThreshold(firstClick.e, e, doubleClickDist)
          # double click on object
          delete pointers.firstClick[e.pointerId]
          if Objects.findOne(objects[0])?.type == 'text'  # text object
            selectTool 'text', select: focus: true
        else
          pointers.firstClick[e.pointerId] = firstClick =
            id: objects[0]
            e: e
          ## Expire firstClick and cleanup space after doubleClickTime
          setTimeout ->
            if firstClick == pointers.firstClick?[e.pointerId] # unchanged
              delete pointers.firstClick[e.pointerId]
          , doubleClickTime
    h?.clear()
    delete pointers[e.pointerId]
  move: (e) ->
    pointers[e.pointerId] ?= new Highlighter currentBoard()
    h = pointers[e.pointerId]
    if h.down
      if h.selector?
        h.selectorUpdate currentBoard().eventToPoint e
      else if eventDistanceThreshold h.down, e, dragDist
        h.down = true
        here = currentBoard().eventToPoint e
        here = orthogonalPoint here, e, h.start
        motion =
          x: here.x - h.start.x
          y: here.y - h.start.y
        motion = maybeSnapPointToGrid motion
        ## Don't set h.moved out here in case no objects selected
        diffs = {}
        for id, obj of pointers.objects when obj?
          h.moved ?= {}
          tx = (obj.tx ? 0) + motion.x
          ty = (obj.ty ? 0) + motion.y
          continue if h.moved[id]?.tx == tx and h.moved[id]?.ty == ty
          diffs[id] = {id, tx, ty}
          h.moved[id] = {tx, ty}
        h.edit diffs if (id for id of diffs).length
    else
      target = h.eventTop e
      if target?
        h.highlight target
      else
        h.clear()
  select: (ids) ->
    currentBoard().selection.addId id for id in ids

defineTool
  name: 'anchor'
  category: 'mode'
  icon: 'anchor-select'
  hotspot: [0.31, 0.16992]
  help: <>Select anchor handles to reshape lines, rectangles, and ellipses. Drag anchor to move it; or drag rectangle or click on individual anchors (toggling multiple if holding <kbd>Shift</kbd>) and then move by dragging (<kbd>Shift</kbd> for horizontal/vertical) or using arrow keys (<kbd>Shift</kbd> for half-grid).</>
  hotkey: 'a'
  start: ->
    mainBoard.showAnchors true
    pointers.objects = {}
  stop: ->
    ## currentBoard().showAnchors fails when switching to history mode
    mainBoard.showAnchors false
    delete pointers.objects
  down: (e) ->
    anchorSelection = currentBoard().anchorSelection
    pointers[e.pointerId] ?= new Highlighter currentBoard()
    h = pointers[e.pointerId]
    return if h.down  # in case of repeat events
    h.down = e
    h.start = currentBoard().eventToPoint e
    h.moved = null
    h.edit = throttle.func (diffs) ->
      Meteor.call 'objectsEdit', (diff for id, diff of diffs)
    , ([older], [newer]) ->
      [Object.assign older, newer]
    ## Check for clicking on a selected anchor, to ensure dragging selection
    ## works even when another anchor is more topmost.
    anchor = anchorFromEvent e, anchorSelection
    ## Deselect existing selection unless requesting multiselect
    toggle = e.shiftKey or e.ctrlKey or e.metaKey
    unless toggle or anchor?.selected
      anchorSelection.clear()
    ## If we clicked on an anchor, then we update the selection
    ## and prepare for dragging it
    if anchor?
      unless anchorSelection.has anchor
        anchorSelection.add anchor
      else if toggle
        anchorSelection.remove anchor
        ## Prevent dragging after deselecting an object
        h.start = null
    ## If we click on blank space, then we draw a selection rectangle.
    else
      h.selectorStart h.start
    ## Refresh selected objects, in particular so pts and anchors up-to-date
    pointers.objects = {}
    for id in anchorSelection.ids()
      pointers.objects[id] = obj = Objects.findOne id
      obj.anchors = rawAnchorsOf obj
  move: (e) ->
    pointers[e.pointerId] ?= new Highlighter currentBoard()
    h = pointers[e.pointerId]
    if h.down
      if h.selector?
        h.selectorUpdate currentBoard().eventToPoint e
      else if eventDistanceThreshold h.down, e, dragDist
        h.down = true
        here = currentBoard().eventToPoint e
        here = orthogonalPoint here, e, h.start
        motion =
          x: here.x - h.start.x
          y: here.y - h.start.y
        motion = maybeSnapPointToGrid motion
        ## Don't set h.moved out here in case no objects selected
        anchorSelection = currentBoard().anchorSelection
        diffs = {}
        for id, obj of pointers.objects when obj?
          continue unless anchorSelection.hasId id
          h.moved ?= {}
          h.moved[id] ?= {}
          moved = false
          for index in anchorSelection.indicesForId id
            x = obj.anchors[index].x + motion.x
            y = obj.anchors[index].y + motion.y
            moved or= anchorMove obj, h.moved[id], index, {x, y}
          continue unless moved
          diffs[id] = {id, pts: h.moved[id]}
        h.edit diffs if (id for id of diffs).length
  up: (e) ->
    h = pointers[e.pointerId]
    if h?.selector?  # finished rectangular drag
      board = currentBoard()
      {render, anchorSelection} = board
      query = BBox.fromPoints [h.start, board.eventToPoint e]
      h.selectorClear()
      for id of render.anchors ? {}
        continue unless render.bbox[id]?.intersects query
        for anchor, index in anchorsOf Objects.findOne id
          if query.containsPoint anchor
            anchorSelection.toggle id, index
    else if h?.moved  # finished dragging objects
      h.edit.flush()
      undoStack.push
        type: 'multi'
        ops:
          for id, obj of pointers.objects when obj?
            type: 'edit'
            id: id
            before:
              pts: obj.pts
            after:
              pts: h.moved[id]
    ###
    else if h?.down != true  # finished regular click without drag
      objects = (id for id of pointers.objects)
      if objects.length == 1  # clicked on an object
        if (firstClick = pointers.firstClick[e.pointerId])? and
           firstClick.id == objects[0] and
           not eventDistanceThreshold(firstClick.e, e, doubleClickDist)
          # double click on object
          delete pointers.firstClick[e.pointerId]
          if Objects.findOne(objects[0])?.type == 'text'  # text object
            selectTool 'text', select: focus: true
        else
          pointers.firstClick[e.pointerId] = firstClick =
            id: objects[0]
            e: e
          ## Expire firstClick and cleanup space after doubleClickTime
          setTimeout ->
            if firstClick == pointers.firstClick?[e.pointerId] # unchanged
              delete pointers.firstClick[e.pointerId]
          , doubleClickTime
    ###
    #h?.clear()
    delete pointers[e.pointerId]

defineTool
  name: 'pen'
  category: 'mode'
  icon: 'pencil-alt'
  hotspot: [0, 1]
  help: 'Freehand drawing (with pen pressure adjusting width)'
  hotkey: 'p'
  down: (e) ->
    return if pointers[e.pointerId]
    object =
      room: currentRoom().id
      page: currentPage().id
      type: 'pen'
      pts: [currentBoard().eventToPointW e]
      color: currentColor()
      width: currentWidth()
      dash: currentDash()
    object.arrowStart = currentArrowStart() if currentArrowStart()
    object.arrowEnd = currentArrowEnd() if currentArrowEnd()
    object.opacity = currentOpacity() if currentOpacityOn()
    pointers[e.pointerId] =
      id: Meteor.apply 'objectNew', [object], returnStubValue: true
      push: throttle.method 'objectPush', ([older], [newer]) ->
        console.assert older.id == newer.id
        older.pts.push ...newer.pts
        [older]
  up: (e) ->
    return unless pointers[e.pointerId]
    pointers[e.pointerId].push.flush()
    undoStack.push
      type: 'new'
      obj: Objects.findOne pointers[e.pointerId].id
    delete pointers[e.pointerId]
  move: (e) ->
    return unless pointers[e.pointerId]
    ## iPhone (iOS 13.4, Safari 13.1) sends zero pressure for touch events.
    #if e.pressure == 0
    #  stop e
    #else
    pointers[e.pointerId].push
      id: pointers[e.pointerId].id
      pts:
        for e2 in e.getCoalescedEvents?() ? [e]
          currentBoard().eventToPointW e2

symmetricPoint = (pt, origin) ->
  x: 2*origin.x - pt.x
  y: 2*origin.y - pt.y

equalXYPoint = (pt, e, origin) ->
  ## When holding Shift, constrain 1:1 aspect ratio from origin, following
  ## the largest delta and maintaining their signs (like Illustrator).
  if e.shiftKey
    dx = pt.x - origin.x
    dy = pt.y - origin.y
    adx = Math.abs dx
    ady = Math.abs dy
    if adx > ady
      pt.y = origin.y + adx * (Math.sign(dy) or 1)
    else if adx < ady
      pt.x = origin.x + ady * (Math.sign(dx) or 1)
  pt

orthogonalPoint = (pt, e, origin) ->
  ## Force horizontal/vertical line from origin when holding shift
  if e.shiftKey
    dx = Math.abs pt.x - origin.x
    dy = Math.abs pt.y - origin.y
    if dx > dy
      pt.y = origin.y
    else
      pt.x = origin.x
  pt

rectLikeTool = (type, fillable, constrain) ->
  down: (e) ->
    return if pointers[e.pointerId]
    origin = maybeSnapPointToGrid currentBoard().eventToPoint e
    width = currentWidth()
    if type == 'poly'
      pts = [origin, origin]
    else  # start rect and ellipse as dot
      pts = [
        {x: origin.x - 2*width, y: origin.y - 2*width}
        {x: origin.x + 2*width, y: origin.y + 2*width}
      ]
    object =
      room: currentRoom().id
      page: currentPage().id
      type: type
      pts: pts
      color: currentColor()
      width: width
    object.dash = currentDash() if currentDash()
    object.fill = currentFill() if fillable and currentFillOn()
    object.opacity = currentOpacity() if currentOpacityOn()
    if type == 'poly'
      object.arrowStart = currentArrowStart() if currentArrowStart()
      object.arrowEnd = currentArrowEnd() if currentArrowEnd()
    pointers[e.pointerId] =
      origin: origin
      start: e
      dot: true
      id: Meteor.apply 'objectNew', [object], returnStubValue: true
      edit: throttle.method 'objectEdit', ([edit1], [edit2]) ->
        ## Add older pts[0] updates to newer updates
        edit2.pts = Object.assign {}, edit1.pts, edit2.pts
        [edit2]
  up: (e) ->
    return unless pointers[e.pointerId]
    pointers[e.pointerId].edit.flush()
    undoStack.push
      type: 'new'
      obj: Objects.findOne pointers[e.pointerId].id
    delete pointers[e.pointerId]
  move: (e) ->
    return unless pointers[e.pointerId]
    {id, origin, start, dot, alt, last, edit} = pointers[e.pointerId]
    # Stay in dot mode until we drag a nontrivial distance
    return if dot and not eventDistanceThreshold e, start, dotDist
    pt = maybeSnapPointToGrid currentBoard().eventToPoint e
    pt = constrain pt, e, origin
    # Stay in dot mode until grid snapping lets us escape the origin
    return if dot and not distanceThreshold pt, origin, minSvgSize
    pointers[e.pointerId].dot = false  # Passed threshold from now on
    pts =
      1: pt
    ## When holding Alt/Option, make origin be the center.
    if e.altKey
      pts[0] = symmetricPoint pts[1], origin
    else if alt or dot  # was holding down Alt or was in dot mode
      # => go back to original first point
      pts[0] = origin
    pointers[e.pointerId].alt = e.altKey
    return if JSON.stringify(last) == JSON.stringify(pts)
    pointers[e.pointerId].last = pts
    edit
      id: id
      pts: pts

defineTool Object.assign rectLikeTool('poly', false, orthogonalPoint),
  name: 'segment'
  category: 'mode'
  icon: 'segment'
  hotspot: [0.0625, 0.9375]
  help: <>Draw straight line segment between endpoints (drag). Hold <kbd>Shift</kbd> to constrain to horizontal/vertical, <kbd>{Alt}</kbd> to center at first point.</>
  hotkey: ['l', '\\']

defineTool Object.assign rectLikeTool('rect', true, equalXYPoint),
  name: 'rect'
  category: 'mode'
  icon: 'rect'
  iconFill: 'rect-fill'
  hotspot: [0.0625, 0.883]
  help: <>Draw axis-aligned rectangle between endpoints (drag). Hold <kbd>Shift</kbd> to constrain to square, <kbd>{Alt}</kbd> to center at first point. Click without dragging to center a square dot proportional to line width.</>
  hotkey: 'r'

defineTool Object.assign rectLikeTool('ellipse', true, equalXYPoint),
  name: 'ellipse'
  category: 'mode'
  icon: 'ellipse'
  iconFill: 'ellipse-fill'
  hotspot: [0.201888, 0.75728]
  help: <>Draw axis-aligned ellipsis inside rectangle between endpoints (drag). Hold <kbd>Shift</kbd> to constrain to circle, <kbd>{Alt}</kbd> to center at first point. Click without dragging to center a circular dot proportional to line width.</>
  hotkey: 'o'

defineTool
  name: 'eraser'
  category: 'mode'
  icon: 'eraser'
  hotspot: [0.4, 0.9]
  help: 'Erase entire objects: click for one object, drag for multiple objects'
  hotkey: 'x'
  down: (e) ->
    pointers[e.pointerId] ?= new Highlighter currentBoard()
    h = pointers[e.pointerId]
    return if h.down  # repeat events can happen because of erasure
    h.down = e
    h.deleted = []
    if h.id?  # already have something highlighted
      h.deleted.push Objects.findOne h.id
      Meteor.call 'objectDel', h.id
      h.clear()
    else  # see if we pressed on something
      target = h.eventTop e
      if target?
        h.deleted.push Objects.findOne target.dataset.id
        Meteor.call 'objectDel', target.dataset.id
  up: (e) ->
    h = pointers[e.pointerId]
    h?.clear()
    if h?.deleted?.length
      ## The following is similar to Selection.delete:
      undoStack.push
        type: 'multi'
        ops:
          for obj in h.deleted
            type: 'del'
            obj: obj
    delete pointers[e.pointerId]
  move: (e) ->
    pointers[e.pointerId] ?= new Highlighter currentBoard()
    h = pointers[e.pointerId]
    target = h.eventCoalescedTop e
    if target?
      if eventDistanceThreshold h.down, e, eraseDist
        h.down = true
        h.deleted.push Objects.findOne target.dataset.id
        Meteor.call 'objectDel', target.dataset.id
        h.clear()
      else
        h.highlight target
    else
      h.clear()

defineTool
  name: 'text'
  category: 'mode'
  icon: 'text'
  hotspot: [.77, .89]
  help: <>Type text (click location or existing text, then type at bottom), including Markdown *<i>italic</i>*, **<b>bold</b>**, ***<b><i>bold italic</i></b>***, `<code>code</code>`, ~~<s>strike</s>~~, and LaTeX $math$, $$displaymath$$</>
  hotkey: 't'
  updateTextCursor: ->
    setTimeout ->
      return unless pointers.text?
      currentPage().render.render Objects.findOne(pointers.text), text: true
    , 0
  startEffect: ->
    @resetInput true
    @updateTextCursor()
    input = document.getElementById 'textInput'
    onCleanup dom.listen input,
      keydown: (e) =>
        if e.key == 'Tab'  # insert tab symbol instead of going to next element
          e.preventDefault()
          unless document.execCommand 'insertText', false, '\t'
            ## Firefox doesn't support execCommand 'insertText' in textarea.
            ## [https://bugzilla.mozilla.org/show_bug.cgi?id=1220696]
            ## Simulate the effect, but mess up the undo stack.
            pos = input.selectionStart
            input.value = input.value[...pos] + '\t' +
                          input.value[input.selectionEnd..]
            input.selectionStart = input.selectionEnd = pos + 1
          onInput()
        e.stopPropagation() # avoid hotkeys
        e.target.blur() if e.key == 'Escape'
        @updateTextCursor e
      click: => @updateTextCursor()
      paste: => @updateTextCursor()
      input: onInput = (e) ->
        return unless pointers.text?
        text = input.value
        if text != (oldText = Objects.findOne(pointers.text).text)
          Meteor.call 'objectEdit',
            id: pointers.text
            text: text
          unless pointers.undoable?
            undoStack.push pointers.undoable =
              type: 'edit'
              id: pointers.text
              before: text: oldText
              after: text: text
          switch pointers.undoable.type
            when 'new'
              pointers.undoable.obj.text = text
            when 'edit'
              pointers.undoable.after.text = text
  start: ->
    pointers.highlight = new Highlighter currentBoard(), 'text'
    pointers.undoable = null
    pointers.text = null
    currentBoard().onRemove = (id) =>
      if pointers.text == id  # someone deleted text object while selected
        @stop()
        @start()
  stop: ->
    delete currentBoard().onRemove
    pointers.cursor?.remove()
    pointers.cursor = null
    return unless (id = pointers.text)?
    if (object = Objects.findOne id)?
      unless object.text
        undoStack.remove pointers.undoable
        Meteor.call 'objectDel', id
    pointers.undoable = null
    pointers.text = null
  up: (e) ->
    return unless e.type == 'pointerup' # ignore pointerleave
    ## Stop editing any previous text object.
    tools.text.stop()
    mainBoard.selection.clear()
    ## In future, may support dragging a rectangular container for text,
    ## but maybe only after SVG 2's <text> flow support...
    h = pointers.highlight
    unless h.id?
      if (target = h.eventTop e)?
        h.highlight target
    if h.id?
      pointers.text = h.id
      mainBoard.selection.add h
      mainBoard.selection.setAttributes()
      text = Objects.findOne(pointers.text)?.text ? ''
    else
      object =
        room: currentRoom().id
        page: currentPage().id
        type: 'text'
        pts: [maybeSnapPointToGrid currentBoard().eventToPoint e]
        text: text = ''
        color: currentColor()
        fontSize: currentFontSize()
      object.opacity = currentOpacity() if currentOpacityOn()
      pointers.text = Meteor.apply 'objectNew', [object], returnStubValue: true
      mainBoard.selection.addId pointers.text
      undoStack.push pointers.undoable =
        type: 'new'
        obj: Objects.findOne pointers.text
    @resetInput true, text
    @updateTextCursor()
  move: (e) ->
    h = pointers.highlight
    target = h.eventTop e
    if target? and Objects.findOne(target.dataset.id).type == 'text'
      h.highlight target
    else
      h.clear()
  select: (ids, options) ->
    return unless ids.length == 1
    return if pointers.text == ids[0]
    obj = Objects.findOne ids[0]
    return unless obj?.type == 'text'
    tools.text.stop()
    mainBoard.selection.clear()
    pointers.text = obj._id
    mainBoard.selection.addId pointers.text
    ## Giving the input focus makes it hard to do repeated global undo/redo;
    ## instead the text-entry box does its own undo/redo.
    @resetInput options?.focus, obj.text
  resetInput: (focus, text) ->
    input = document.getElementById 'textInput'
    return unless input?
    if pointers.text?
      input.value = text ? Objects.findOne(pointers.text)?.text
      input.disabled = false
      input.focus() if focus
    else
      input.value = ''
      input.disabled = true

defineTool
  name: 'image'
  category: 'mode'
  icon: 'image'
  hotspot: [0.21875, 0.34375]
  help: 'Embed image (SVG, JPG, PNG, etc.) on web by entering its URL at bottom. Click on existing image to modify URL, or a point to specify location. You can also paste an image URL from the clipboard, or drag an image from a webpage (without needing this tool).'
  startEffect: ->
    @resetInput true
    input = document.getElementById 'urlInput'
    onCleanup dom.listen input,
      keydown: (e) ->
        e.stopPropagation() # avoid hotkeys
        e.target.blur() if e.key == 'Escape'
        updateUrl e if e.key == 'Enter'  # force rechecking URL
      input: (e) ->
        input.className = 'pending'
      change: updateUrl = debounce (e) ->
        url = input.value
        old = if pointers.image then Objects.findOne pointers.image
        #return if url == old?.url
        obj = await tryAddImageUrl url, objOnly: true
        input.className = if obj? then 'success' else 'error'
        return unless obj?
        unless old?
          obj.pts = [pointers.point ?
                      maybeSnapPointToGrid currentBoard().relativePoint 0.25, 0.25]
          obj.opacity = currentOpacity() if currentOpacityOn()
          undoStack.pushAndDo pointers.undoable =
            type: 'new'
            obj: obj
          pointers.image = obj._id
        else
          return if obj.url == old.url and
            obj.credentials == old.credentials and obj.proxy == old.proxy
          edit =
            id: pointers.image
            url: obj.url
            credentials: obj.credentials
            proxy: obj.proxy
          Meteor.call 'objectEdit', edit
          delete edit.id
          unless pointers.undoable?
            undoStack.push pointers.undoable =
              type: 'edit'
              id: pointers.image
              before:
                url: old.url
                credentials: old.credentials
                proxy: old.proxy
              after: edit
          switch pointers.undoable.type
            when 'new'
              Object.assign pointers.undoable.obj, edit
            when 'edit'
              Object.assign pointers.undoable.after, edit
      , 50
  start: ->
    pointers.highlight = new Highlighter currentBoard(), 'image'
    pointers.undoable = null
    pointers.image = null
    pointers.point = null
  stop: ->
    return unless (id = pointers.image)?
    if (object = Objects.findOne id)?
      unless object.url
        undoStack.remove pointers.undoable
        Meteor.call 'objectDel', id
    pointers.undoable = null
    pointers.image = null
  up: (e) ->
    return unless e.type == 'pointerup' # ignore pointerleave
    ## Stop editing any previous image object.
    tools.image.stop()
    mainBoard.selection.clear()
    h = pointers.highlight
    unless h.id?
      if (target = h.eventTop e)?
        h.highlight target
    if h.id?
      pointers.image = h.id
      mainBoard.selection.add h
      mainBoard.selection.setAttributes()
      url = Objects.findOne(pointers.image)?.url ? ''
    else
      pointers.point = maybeSnapPointToGrid currentBoard().eventToPoint e
      url = ''
    @resetInput true, url
  move: (e) ->
    h = pointers.highlight
    target = h.eventTop e
    if target? and Objects.findOne(target.dataset.id).type == 'image'
      h.highlight target
    else
      h.clear()
  select: (ids) ->
    return unless ids.length == 1
    return if pointers.image == ids[0]
    obj = Objects.findOne ids[0]
    return unless obj?.type == 'image'
    tools.image.stop()
    mainBoard.selection.clear()
    pointers.image = obj._id
    mainBoard.selection.addId pointers.image
    ## Giving the input focus makes it hard to do repeated global undo/redo;
    ## instead the text-entry box does its own undo/redo.
    @resetInput false, obj.url
  resetInput: (focus, url) ->
    input = document.getElementById 'urlInput'
    return unless input?
    if pointers.image?
      input.value = url ? Objects.findOne(pointers.image)?.url
    else
      input.value = ''
    input.focus() if focus
    input.className = ''

## Resets the selection, and if the current tool supports selection,
## sets the selection to the specified array of object IDs
## (as e.g. returned by `UndoStack.undo` and `UndoStack.redo`).
## Does nothing if `objIds` is undefined (as when `undo` or `redo` failed).
export setSelection = (objIds) ->
  return unless objIds?
  mainBoard.selection.clear()
  highlighterClear()
  tools[currentTool()]?.select? objIds
