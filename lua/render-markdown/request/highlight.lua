---@class render.md.request.highlight.Value
---@field start_col integer
---@field end_col integer
---@field highlight render.md.mark.Hl

---@class render.md.request.Highlight
---@field private buf integer
---@field private values table<integer, render.md.request.highlight.Value[]>
local Highlight = {}
Highlight.__index = Highlight

---@param buf integer
---@return render.md.request.Highlight
function Highlight.new(buf)
    local self = setmetatable({}, Highlight)
    self.buf = buf
    self.values = {}
    return self
end

---@param row integer
---@param value render.md.request.highlight.Value
function Highlight:add(row, value)
    if not self.values[row] then
        self.values[row] = {}
    end
    self.values[row][#self.values[row] + 1] = value
end

---@param row integer
---@param start_col integer
---@param end_col integer
---@param default render.md.mark.Hl
---@return render.md.mark.Hl
function Highlight:get(row, start_col, end_col, default)
    local result = default
    local priority = -math.huge
    local ok, captures =
        pcall(vim.treesitter.get_captures_at_pos, self.buf, row, start_col)
    if ok then
        for _, capture in ipairs(captures) do
            local name = capture.capture
            if
                name
                and name ~= 'spell'
                and name ~= 'nospell'
                and not vim.startswith(name, 'conceal')
            then
                local metadata = capture.metadata or {}
                local capture_priority = tonumber(metadata.priority) or 100
                if capture.lang == 'markdown_inline' then
                    capture_priority = capture_priority + 1
                end
                if capture_priority >= priority then
                    result = '@' .. name
                    priority = capture_priority
                end
            end
        end
    end
    for _, value in ipairs(self.values[row] or {}) do
        if start_col < value.end_col and end_col > value.start_col then
            result = value.highlight
        end
    end
    return result
end

return Highlight
