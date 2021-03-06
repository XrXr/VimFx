###
# Copyright Anton Khodakivskiy 2012, 2013.
# Copyright Simon Lydell 2013, 2014, 2015, 2016.
#
# This file is part of VimFx.
#
# VimFx is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# VimFx is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VimFx.  If not, see <http://www.gnu.org/licenses/>.
###

# This file contains functions for getting markable elements and related data.

utils = require('./utils')
viewportUtils = require('./viewport')

{devtools} = Cu.import('resource://devtools/shared/Loader.jsm', {})

Element = Ci.nsIDOMElement
XULDocument = Ci.nsIDOMXULDocument

find = (window, filter, selector = '*') ->
  viewport = viewportUtils.getWindowViewport(window)
  wrappers = []
  _getMarkableElements(window, viewport, wrappers, filter, selector)
  return wrappers

# `filter` is a function that is given every element in every frame of the page.
# It should return wrapper objects for markable elements and a falsy value for
# all other elements. All returned wrappers are added to `wrappers`. `wrappers`
# is modified instead of using return values to avoid array concatenation for
# each frame. It might sound expensive to go through _every_ element, but that’s
# actually what other methods like using XPath or CSS selectors would need to do
# anyway behind the scenes. However, it is possible to pass in a CSS selector,
# which allows getting markable elements in several passes with different sets
# of candidates.
_getMarkableElements = (
  window, viewport, wrappers, filter, selector, parents = []
) ->
  {document} = window

  for element in getAllElements(document, selector)
    continue unless element instanceof Element
    # `getRects` is fast and filters out most elements, so run it first of all.
    rects = getRects(element, viewport)
    continue unless rects.length > 0
    continue unless wrapper = filter(
      element, (elementArg) ->
        return getElementShape(
          window, viewport, parents, elementArg,
          if elementArg == element then rects else null
        )
    )
    wrappers.push(wrapper)

  for frame in window.frames when frame.frameElement
    continue unless result = viewportUtils.getFrameViewport(
      frame.frameElement, viewport
    )
    {viewport: frameViewport, offset} = result
    _getMarkableElements(
      frame, frameViewport, wrappers, filter, selector,
      parents.concat({window, offset})
    )

  return

getAllElements = (document, selector) ->
  unless document instanceof XULDocument
    return document.querySelectorAll(selector)

  # Use a `Set` since this algorithm may find the same element more than once.
  # Ideally we should find a way to find all elements without duplicates.
  elements = new Set()
  getAllRegular = (element) ->
    # The first time `zF` is run `.getElementsByTagName('*')` may oddly include
    # `undefined` in its result! Filter those out. (Also, `selector` is ignored
    # here since it doesn’t make sense in XUL documents because of all the
    # trickery around anonymous elements.)
    for child in element.getElementsByTagName('*') when child
      elements.add(child)
      getAllAnonymous(child)
    return
  getAllAnonymous = (element) ->
    for child in document.getAnonymousNodes(element) or []
      continue unless child instanceof Element
      elements.add(child)
      getAllRegular(child)
    return
  getAllRegular(document.documentElement)
  return Array.from(elements)

getRects = (element, viewport) ->
  # `element.getClientRects()` returns a list of rectangles, usually just one,
  # which is identical to the one returned by `element.getBoundingClientRect()`.
  # However, if `element` is inline and line-wrapped, then it returns one
  # rectangle for each line, since each line may be of different length, for
  # example. That allows us to properly add hints to line-wrapped links.
  return Array.filter(
    element.getClientRects(),
    (rect) -> viewportUtils.isInsideViewport(rect, viewport)
  )

# Returns the “shape” of `element`:
#
# - `nonCoveredPoint`: The coordinates of the first point of `element` that
#   isn’t covered by another element (except children of `element`). It also
#   contains the offset needed to make those coordinates relative to the top
#   frame, as well as the rectangle that the coordinates occur in.
# - `area`: The area of the part of `element` that is inside `viewport`.
#
# Returns `null` if `element` is outside `viewport` or entirely covered by other
# elements.
getElementShape = (window, viewport, parents, element, rects = null) ->
  rects ?= getRects(element, viewport)
  totalArea = 0
  visibleRects = []
  for rect in rects
    visibleRect = viewportUtils.adjustRectToViewport(rect, viewport)
    continue if visibleRect.area == 0
    totalArea += visibleRect.area
    visibleRects.push(visibleRect)

  if visibleRects.length == 0
    if rects.length == 1 and totalArea == 0
      [rect] = rects
      if rect.width > 0 or rect.height > 0
        # If we get here, it means that everything inside `element` is floated
        # and/or absolutely positioned (and that `element` hasn’t been made to
        # “contain” the floats). For example, a link in a menu could contain a
        # span of text floated to the left and an icon floated to the right.
        # Those are still clickable. Therefore we return the shape of the first
        # visible child instead. At least in that example, that’s the best bet.
        for child in element.children
          shape = getElementShape(window, viewport, parents, child)
          return shape if shape
    return null

  # Even if `element` has a visible rect, it might be covered by other elements.
  for visibleRect in visibleRects
    nonCoveredPoint = getFirstNonCoveredPoint(
      window, viewport, element, visibleRect, parents
    )
    break if nonCoveredPoint

  return null unless nonCoveredPoint

  return {
    nonCoveredPoint, area: totalArea
  }

getFirstNonCoveredPoint = (window, viewport, element, elementRect, parents) ->
  # Tries a point `(x + dx, y + dy)`. Returns `(x, y)` (and the frame offset)
  # if it passes the tests. Otherwise it tries to the right of whatever is at
  # `(x, y)`, `tryRight` times . If nothing succeeds, `false` is returned. `dx`
  # and `dy` are used to offset the wanted point `(x, y)` while trying (see the
  # invocations of `tryPoint` below).
  tryPoint = (x, dx, y, dy, tryRight = 0) ->
    elementAtPoint = window.document.elementFromPoint(x + dx, y + dy)
    offset = {left: 0, top: 0}
    found = false
    firstLevel = true

    # Ensure that `element`, or a child of `element` (anything inside an `<a>`
    # is clickable too), really is present at (x,y). Note that this is not 100%
    # bullet proof: Combinations of CSS can cause this check to fail, even
    # though `element` isn’t covered. We don’t try to temporarily reset such CSS
    # because of performance. Instead we rely on that some of the attempts below
    # will work. (See further down for the special value `-1` of `tryRight`.)
    if contains(element, elementAtPoint) or tryRight == -1
      found = true
      # If we’re currently in a frame, there might be something on top of the
      # frame that covers `element`. Therefore we ensure that the frame really
      # is present at the point for each parent in `parents`.
      currentWindow = window
      for parent in parents by -1
        # If leaving the devtools container take the devtools zoom into account.
        if utils.isDevtoolsWindow(currentWindow)
          toolbox = window.top.gDevTools.getToolbox(
            devtools.TargetFactory.forTab(window.top.gBrowser.selectedTab)
          )
          if toolbox
            devtoolsZoom = toolbox.zoomValue
            offset.left *= devtoolsZoom
            offset.top  *= devtoolsZoom
            x  *= devtoolsZoom
            y  *= devtoolsZoom
            dx *= devtoolsZoom
            dy *= devtoolsZoom

        offset.left += parent.offset.left
        offset.top  += parent.offset.top
        elementAtPoint = parent.window.document.elementFromPoint(
          offset.left + x + dx, offset.top + y + dy
        )
        firstLevel = false
        unless contains(currentWindow.frameElement, elementAtPoint)
          found = false
          break
        currentWindow = parent.window

    return {x, y, offset} if found

    return false if elementAtPoint == null or tryRight <= 0
    rect = elementAtPoint.getBoundingClientRect()

    # `.getBoundingClientRect()` does not include pseudo-elements that are
    # absolutely positioned so that they go outside of the element (which is
    # common for `/###\`-looking tabs), but calling `.elementAtPoint()` on the
    # pseudo-element _does_ return the element. This means that the covering
    # element’s _rect_ won’t cover the element we’re looking for. If so, it’s
    # better to try again, forcing the element to be considered located at this
    # point. That’s what `-1` for the `tryRight` argument means.
    if firstLevel and rect.right <= x + offset.left
      return tryPoint(x, dx, y, dy, -1)

    x = rect.right - offset.left + 1
    return false if x > viewport.right
    return tryPoint(x, 0, y, 0, tryRight - 1)


  # Try the left-middle point, or immediately to the right of a covering element
  # at that point. If both of those are covered the whole element is considered
  # to be covered. The reasoning is:
  #
  # - A marker should show up as near the left edge of its visible area as
  #   possible. Having it appear to the far right (for example) is confusing.
  # - We can’t try too many times because of performance.
  # - We used to try left-top first, but if `element` has `border-radius`, the
  #   corners won’t really belong to `element`, so `document.elementFromPoint()`
  #   will return whatever is behind. This will result in missing or
  #   out-of-place markers. The solution is to temporarily add a CSS class that
  #   removes `border-radius`, but that turned out to be rather slow, making it
  #   not worth it. Usually you don’t see the difference between left-top and
  #   left-middle, because links are usually not that high.
  # - We used to try left-bottom as well, but that is so rare that it’s not
  #   worth it.
  #
  # It is safer to try points at least one pixel into the element from the
  # edges, hence the `+1`.
  {left, top, bottom, height} = elementRect
  nonCoveredPoint = tryPoint(left, +1, Math.floor(top + height / 2), 0, 1)

  return nonCoveredPoint

# In XUL documents there are “anonymous” elements. These are never returned by
# `document.elementFromPoint` but their closest non-anonymous parents are.
normalize = (element) ->
  normalized = element.ownerDocument.getBindingParent(element) or element
  normalized = normalized.parentNode while normalized.prefix?
  return normalized

# Returns whether `element` corresponds to `elementAtPoint`. This is only
# complicated for browser elements in the web page content area.
# `.elementAtPoint()` always returns `<tabbrowser#content>` then. The element
# might be in another tab and thus invisible, but `<tabbrowser#content>` is the
# same and visible in _all_ tabs, so we have to check that the element really
# belongs to the current tab.
contains = (element, elementAtPoint) ->
  return false unless elementAtPoint
  container = normalize(element)
  if elementAtPoint.localName == 'tabbrowser' and elementAtPoint.id == 'content'
    {gBrowser} = element.ownerGlobal.top
    tabpanel = gBrowser.getNotificationBox(gBrowser.selectedBrowser)
    return tabpanel.contains(element)
  else
    # Note that `a.contains(a)` is supposed to be true, but strangely aren’t for
    # `<menulist>`s in the Add-ons Manager, so do a direct comparison as well.
    return container == elementAtPoint or container.contains(elementAtPoint)

module.exports = {
  find
}
