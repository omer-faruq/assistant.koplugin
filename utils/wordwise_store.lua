--[[--
Word Wise hint store.

Keeps every hint of a book in document order together with the list of
document ranges that were already analysed ("coverage"). Keyed by position and
not by page number, so the hints survive font-size / margin changes (page
boundaries move, the words don't).

The store knows nothing about KOReader: positions are opaque strings ordered by
an injected comparator

    cmp(a, b) -> 1 if b is after a, 0 if the same, -1 if before, nil if invalid

which in the plugin is CreDocument:compareXPointers. That makes the data
structure testable with plain LuaJIT.
]]

local Store = {}
Store.__index = Store

function Store.new(cmp)
  return setmetatable({ cmp = cmp, hints = {}, ranges = {} }, Store)
end

-- a strictly before b
local function before(self, a, b)
  return self.cmp(a, b) == 1
end

-- a before or equal to b
local function before_eq(self, a, b)
  local c = self.cmp(a, b)
  return c == 1 or c == 0
end

--- First index whose p0 is not before `pos` (i.e. p0 >= pos); #hints+1 if none.
local function lower_bound(self, pos)
  local lo, hi = 1, #self.hints + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if before(self, self.hints[mid].p0, pos) then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

function Store:count()
  return #self.hints
end

function Store:clear()
  self.hints = {}
  self.ranges = {}
end

--- Insert one hint { p0, p1, t, h }; replaces a hint starting at the same spot.
function Store:addHint(rec)
  local i = lower_bound(self, rec.p0)
  local cur = self.hints[i]
  if cur and (cur.p0 == rec.p0 or self.cmp(cur.p0, rec.p0) == 0) then
    self.hints[i] = rec
  else
    table.insert(self.hints, i, rec)
  end
end

--- Hints whose start lies in [a, b). b == nil means "to the end of the book".
--- @return table[] hints in document order
function Store:query(a, b)
  local out = {}
  local i = lower_bound(self, a)
  while i <= #self.hints do
    local h = self.hints[i]
    if b and not before(self, h.p0, b) then break end
    out[#out + 1] = h
    i = i + 1
  end
  return out
end

--- Index of the (merged) range containing position a, or nil.
local function range_containing(self, a)
  for i, r in ipairs(self.ranges) do
    if before_eq(self, r.a, a) and (r.inf or before(self, a, r.b)) then
      return i, r
    end
  end
end

--- Has [a, b) been analysed completely? b == nil means "to the end of the book".
function Store:covers(a, b)
  local _, r = range_containing(self, a)
  if not r then return false end
  if r.inf then return true end
  if b == nil then return false end
  return before_eq(self, b, r.b)
end

--- Record that [a, b) was analysed and yielded `hints`.
--- Overlapping or touching ranges are merged.
function Store:addRange(a, b, hints)
  for _, rec in ipairs(hints or {}) do
    self:addHint(rec)
  end

  local new = { a = a, b = b, inf = (b == nil) or nil }
  local keep = {}
  for _, r in ipairs(self.ranges) do
    -- r overlaps or touches new?  r.a <= new.b  and  new.a <= r.b
    local left_ok = new.inf or before_eq(self, r.a, new.b)
    local right_ok = r.inf or before_eq(self, new.a, r.b)
    if left_ok and right_ok then
      if before(self, r.a, new.a) then new.a = r.a end
      if r.inf then
        new.inf, new.b = true, nil
      elseif not new.inf and before(self, new.b, r.b) then
        new.b = r.b
      end
    else
      keep[#keep + 1] = r
    end
  end
  -- insert keeping order by .a
  local pos = #keep + 1
  for i, r in ipairs(keep) do
    if before(self, new.a, r.a) then
      pos = i
      break
    end
  end
  table.insert(keep, pos, new)
  self.ranges = keep
end

--- Serializable snapshot (plain tables of strings).
function Store:dump()
  return { hints = self.hints, ranges = self.ranges }
end

--- Rebuild a store from a snapshot, or nil when it fails validation.
--- @param cmp function xpointer comparator
--- @param data table snapshot from dump()
--- @param is_valid function|nil position -> boolean (e.g. isXPointerInDocument)
function Store.load(cmp, data, is_valid)
  if type(data) ~= "table" or type(data.hints) ~= "table" or type(data.ranges) ~= "table" then
    return nil
  end
  for _, h in ipairs(data.hints) do
    if type(h) ~= "table" or type(h.p0) ~= "string" or type(h.p1) ~= "string"
        or type(h.h) ~= "string" then
      return nil
    end
  end
  for _, r in ipairs(data.ranges) do
    if type(r) ~= "table" or type(r.a) ~= "string" or (not r.inf and type(r.b) ~= "string") then
      return nil
    end
  end
  if is_valid then
    -- Spot-check: a changed DOM (new engine version, other book file) makes
    -- stored positions meaningless.
    local probes = {}
    local hn = #data.hints
    if hn > 0 then
      probes[#probes + 1] = data.hints[1].p0
      probes[#probes + 1] = data.hints[math.ceil(hn / 2)].p0
      probes[#probes + 1] = data.hints[hn].p1
    end
    if #data.ranges > 0 then
      probes[#probes + 1] = data.ranges[1].a
    end
    for _, p in ipairs(probes) do
      if not is_valid(p) then return nil end
    end
  end
  local s = Store.new(cmp)
  s.hints = data.hints
  s.ranges = data.ranges
  return s
end

return Store
