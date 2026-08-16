local Base = require('render-markdown.render.base')
local compat = require('render-markdown.lib.compat')
local env = require('render-markdown.lib.env')
local iter = require('render-markdown.lib.iter')
local log = require('render-markdown.core.log')
local str = require('render-markdown.lib.str')

---@class render.md.table.Data
---@field layout render.md.table.Layout
---@field delim render.md.Node
---@field cols render.md.table.Col[]
---@field rows render.md.table.Row[]

---@class render.md.table.Layout
---@field col integer
---@field valid boolean

---@class render.md.table.Col
---@field width integer
---@field alignment render.md.table.col.Alignment

---@enum render.md.table.col.Alignment
local Alignment = {
    left = 'left',
    right = 'right',
    center = 'center',
    default = 'default',
}

---@class render.md.table.Row
---@field node render.md.Node
---@field pipes render.md.Node[]
---@field cells render.md.table.row.Cell[]

---@class render.md.table.row.Cell
---@field node render.md.Node
---@field width integer
---@field space render.md.table.cell.Space

---@class render.md.table.cell.Space
---@field left integer
---@field right integer

---@class render.md.table.row.Parts
---@field pipes render.md.Node[]
---@field cells render.md.Node[]

---@class render.md.table.Virtual
---@field start_row integer
---@field end_row integer
---@field anchor_row integer
---@field above boolean

---@class render.md.render.Table: render.md.Render
---@field private config render.md.table.Config
---@field private data render.md.table.Data
---@field private row_count integer
---@field private virtual? render.md.table.Virtual
local Render = setmetatable({}, Base)
Render.__index = Render

---@protected
---@return boolean
function Render:setup()
    self.config = self.context.config.pipe_table
    if not self.config.enabled then
        return false
    end

    -- ensure delimiter and rows exist
    local delim = nil ---@type render.md.Node?
    local row_nodes = {} ---@type render.md.Node[]
    self.row_count = 0
    local types = {
        delim = 'pipe_table_delimiter_row',
        row = { 'pipe_table_header', 'pipe_table_row' },
        skip = { 'block_continuation' },
    }
    self.node:for_each_child(function(node)
        if node.type == types.delim then
            delim = node
        elseif vim.tbl_contains(types.row, node.type) then
            self.row_count = self.row_count + 1
            if self.context.view:overlaps(node:get()) then
                row_nodes[#row_nodes + 1] = node
            end
        elseif
            self.context.view:overlaps(node:get())
            and not vim.tbl_contains(types.skip, node.type)
        then
            log.unhandled(self.context.buf, 'markdown', 'row', node.type)
        end
    end)
    if not delim or #row_nodes == 0 then
        return false
    end

    ---@type render.md.table.Layout
    local layout = { col = delim:col(), valid = true }

    local cols = self:parse_cols(delim)
    if not cols then
        return false
    end

    local rows = {} ---@type render.md.table.Row[]
    table.sort(row_nodes)
    for _, row_node in ipairs(row_nodes) do
        local row = self:parse_row(row_node, #cols)
        if row then
            if row.node:col() ~= layout.col then
                layout.valid = false
            end
            rows[#rows + 1] = row
        end
    end
    if #rows == 0 then
        return false
    end

    -- store the max width in cols
    for _, row in ipairs(rows) do
        for i, cell in ipairs(row.cells) do
            local space = cell.space.left + cell.space.right
            local available = space - (2 * self.config.padding)
            -- if we don't have enough space for padding add it to the width
            local width = cell.width
            if available < 0 then
                width = width - available
            end
            if self.config.cell == 'trimmed' then
                width = width - math.max(available, 0)
            end
            cols[i].width = math.max(cols[i].width, width)
        end
    end

    self.data = { layout = layout, delim = delim, cols = cols, rows = rows }
    self.virtual = self:virtual_data()

    return true
end

---@private
---@param node render.md.Node
---@return render.md.table.Col[]?
function Render:parse_cols(node)
    local parts = self:parse_row_parts(node, 'pipe_table_delimiter_cell')
    if not parts then
        return nil
    end
    local cols = {} ---@type render.md.table.Col[]
    for i, cell in ipairs(parts.cells) do
        local start_col = parts.pipes[i].end_col
        local end_col = parts.pipes[i + 1].start_col
        local width = end_col - start_col
        assert(width >= 0, 'invalid table layout')
        if self.config.cell == 'padded' then
            width = math.max(width, self.config.min_width)
        elseif self.config.cell == 'trimmed' then
            width = self.config.min_width
        end
        cols[#cols + 1] = {
            width = width,
            alignment = Render.alignment(cell),
        }
    end
    return cols
end

---@private
---@param node render.md.Node
---@return render.md.table.col.Alignment
function Render.alignment(node)
    local left = node:child('pipe_table_align_left')
    local right = node:child('pipe_table_align_right')
    if left and right then
        return Alignment.center
    elseif left then
        return Alignment.left
    elseif right then
        return Alignment.right
    else
        return Alignment.default
    end
end

---@private
---@param node render.md.Node
---@param num_cols integer
---@return render.md.table.Row?
function Render:parse_row(node, num_cols)
    local parts = self:parse_row_parts(node, 'pipe_table_cell')
    if not parts or #parts.cells ~= num_cols then
        return nil
    end
    local cells = {} ---@type render.md.table.row.Cell[]
    for i, cell in ipairs(parts.cells) do
        -- account for double width glyphs by replacing cell range with width
        local start_col = parts.pipes[i].end_col
        local end_col = parts.pipes[i + 1].start_col
        local width = (end_col - start_col)
            - (cell.end_col - cell.start_col)
            + self.context:width(cell)
            + self.config.cell_offset({ node = cell:get() })
        assert(width >= 0, 'invalid table layout')
        cells[#cells + 1] = {
            node = cell,
            width = width,
            space = {
                -- gap between the cell start and the pipe start
                left = math.max(cell.start_col - start_col, 0),
                -- attached to the end of the cell itself
                right = math.max(str.spaces('end', cell.text), 0),
            },
        }
    end
    ---@type render.md.table.Row
    return { node = node, pipes = parts.pipes, cells = cells }
end

---@private
---@param node render.md.Node
---@param cell_type string
---@return render.md.table.row.Parts?
function Render:parse_row_parts(node, cell_type)
    local pipes = {} ---@type render.md.Node[]
    local cells = {} ---@type render.md.Node[]
    node:for_each_child(function(child)
        if child.type == '|' then
            pipes[#pipes + 1] = child
        elseif child.type == cell_type then
            cells[#cells + 1] = child
        else
            log.unhandled(self.context.buf, 'markdown', 'cell', child.type)
        end
    end)
    if #pipes == 0 or #cells == 0 or #pipes ~= #cells + 1 then
        return nil
    end
    table.sort(pipes)
    table.sort(cells)
    ---@type render.md.table.row.Parts
    return { pipes = pipes, cells = cells }
end

---@private
---@param node render.md.Node
---@return render.md.Line
function Render:prefix_line(node)
    local _, source = node:line('first', 0)
    local raw = (source or ''):sub(1, node.start_col)
    local line = self:line()

    ---@class render.md.table.PrefixMark
    ---@field order integer
    ---@field start_col integer
    ---@field end_col integer
    ---@field position? string
    ---@field conceal boolean
    ---@field virt_text? render.md.mark.Line
    local marks = {} ---@type render.md.table.PrefixMark[]
    for order, mark in ipairs(self.marks:get()) do
        local opts = mark.opts
        local position = opts.virt_text_pos
        local display = vim.tbl_contains({ 'inline', 'overlay' }, position)
        if
            mark.start_row == node.start_row
            and mark.start_col <= node.start_col
            and (display or opts.conceal ~= nil)
        then
            marks[#marks + 1] = {
                order = order,
                start_col = mark.start_col,
                end_col = opts.end_col or mark.start_col,
                position = position,
                conceal = opts.conceal ~= nil,
                virt_text = opts.virt_text,
            }
        end
    end
    local rank = { inline = 1, overlay = 2 }
    table.sort(marks, function(a, b)
        if a.start_col ~= b.start_col then
            return a.start_col < b.start_col
        end
        local a_rank, b_rank = rank[a.position] or 3, rank[b.position] or 3
        if a_rank ~= b_rank then
            return a_rank < b_rank
        end
        return a.order < b.order
    end)

    local mark_index, hidden_end = 1, 0
    ---@param mark render.md.table.PrefixMark
    local function add_mark(mark)
        line:extend(mark.virt_text or {})
        if mark.position == 'overlay' or mark.conceal then
            hidden_end = math.max(hidden_end, mark.end_col)
        end
    end

    local bytes = vim.str_utf_pos(raw)
    for index, start_byte in ipairs(bytes) do
        local end_byte = index < #bytes and bytes[index + 1] - 1 or #raw
        local start_col = start_byte - 1
        while
            mark_index <= #marks
            and marks[mark_index].start_col <= start_col
        do
            add_mark(marks[mark_index])
            mark_index = mark_index + 1
        end
        if start_col >= hidden_end then
            line:text(
                raw:sub(start_byte, end_byte),
                self.context.config.padding.highlight
            )
        end
    end
    while
        mark_index <= #marks
        and marks[mark_index].start_col <= node.start_col
    do
        add_mark(marks[mark_index])
        mark_index = mark_index + 1
    end
    return line
end

---@private
---@return render.md.table.Virtual?
function Render:virtual_data()
    if
        not compat.has_11
        or not env.win.get(self.context.win, 'wrap')
        or not self.context.conceal:fully()
    then
        return nil
    end
    if not vim.tbl_contains({ 'trimmed', 'padded' }, self.config.cell) then
        return nil
    end
    -- Rendering the complete table as virtual lines requires every source row.
    if #self.data.rows ~= self.row_count then
        return nil
    end

    local rows, delim = self.data.rows, self.data.delim
    local start_row = math.min(rows[1].node.start_row, delim.start_row)
    local end_row = math.max(rows[#rows].node.start_row, delim.start_row)
    local window_width = env.win.width(self.context.win)

    local prefix_width = self:prefix_line(delim):width()
    for _, row in ipairs(rows) do
        prefix_width =
            math.max(prefix_width, self:prefix_line(row.node):width())
    end
    local rendered_width = prefix_width + #self.data.cols + 1
    for _, col in ipairs(self.data.cols) do
        rendered_width = rendered_width + col.width
    end
    if rendered_width > window_width then
        return nil
    end

    local raw_wraps = false
    for row = start_row, end_row do
        local _, source = self.node:line('first', row - self.node.start_row)
        raw_wraps = raw_wraps or str.width(source) > window_width
    end
    if not raw_wraps then
        return nil
    end

    local line_count = vim.api.nvim_buf_line_count(self.context.buf)
    if end_row + 1 < line_count then
        return {
            start_row = start_row,
            end_row = end_row,
            anchor_row = end_row + 1,
            above = true,
        }
    elseif start_row > 0 then
        return {
            start_row = start_row,
            end_row = end_row,
            anchor_row = start_row - 1,
            above = false,
        }
    else
        return nil
    end
end

---@private
---@param cell render.md.table.row.Cell
---@param highlight string
---@return render.md.Line
function Render:cell_line(cell, highlight)
    local node = cell.node
    local values = self.context.inline:get(node)
    local value_index, replacement_end = 1, 0
    local line = self:line()

    local leading = str.spaces('start', node.text)
    local trailing = str.spaces('end', node.text)
    local raw = node.text:sub(leading + 1, #node.text - trailing)
    local base_col = node.start_col + leading

    ---@param value render.md.request.inline.Value
    local function add_value(value)
        line:extend(value.line)
        if value.replacement then
            replacement_end = math.max(replacement_end, value.end_col)
        end
    end

    while value_index <= #values and values[value_index].col < base_col do
        add_value(values[value_index])
        value_index = value_index + 1
    end

    local bytes = vim.str_utf_pos(raw)
    for index, start_byte in ipairs(bytes) do
        local end_byte = index < #bytes and bytes[index + 1] - 1 or #raw
        local start_col = base_col + start_byte - 1
        local end_col = start_col + end_byte - start_byte + 1
        while value_index <= #values and values[value_index].col <= start_col do
            add_value(values[value_index])
            value_index = value_index + 1
        end
        if
            start_col >= replacement_end
            and not self.context.conceal:contains(
                node.start_row,
                start_col,
                end_col
            )
        then
            local character = raw:sub(start_byte, end_byte)
            local character_highlight = self.context.highlight:get(
                node.start_row,
                start_col,
                end_col,
                highlight
            )
            line:text(character, character_highlight)
        end
    end
    while value_index <= #values do
        add_value(values[value_index])
        value_index = value_index + 1
    end
    return line
end

---@private
---@param row render.md.table.Row
---@return render.md.mark.Line
function Render:virtual_row(row)
    local highlight = row.node.type == 'pipe_table_header' and self.config.head
        or self.config.row
    local line = self:prefix_line(row.node)

    for i, cell in ipairs(row.cells) do
        local col = self.data.cols[i]
        local content = self:cell_line(cell, highlight)
        local available = math.max(col.width - (2 * self.config.padding), 0)
        local filler = math.max(available - content:width(), 0)
        local left, right = 0, filler
        if col.alignment == Alignment.center then
            left = math.floor(filler / 2)
            right = filler - left
        elseif col.alignment == Alignment.right then
            left, right = filler, 0
        end

        line:text(self.config.border[10], highlight)
        line:pad(
            self.config.padding + left,
            self.context.config.padding.highlight
        )
        line:extend(content)
        line:pad(
            self.config.padding + right,
            self.context.config.padding.highlight
        )
    end
    line:text(self.config.border[10], highlight)
    return line:get()
end

---@private
---@return render.md.mark.Line
function Render:virtual_delimiter()
    local border = self.config.border
    local indicator = self.config.alignment_indicator
    local icon = border[11]
    local parts = iter.list.map(self.data.cols, function(col)
        if
            col.width < 3
            or str.width(indicator) ~= 1
            or col.alignment == Alignment.default
        then
            return icon:rep(col.width)
        elseif col.alignment == Alignment.left then
            return indicator .. icon:rep(col.width - 1)
        elseif col.alignment == Alignment.right then
            return icon:rep(col.width - 1) .. indicator
        else
            return indicator .. icon:rep(col.width - 2) .. indicator
        end
    end)
    return self:prefix_line(self.data.delim)
        :text(
            border[4] .. table.concat(parts, border[5]) .. border[6],
            self.config.head
        )
        :get()
end

---@private
---@param above boolean
---@return render.md.mark.Line
function Render:virtual_border(above)
    local rows, border = self.data.rows, self.config.border
    local node = above and rows[1].node or rows[#rows].node
    local chars = above and { border[1], border[2], border[3] }
        or { border[7], border[8], border[9] }
    local parts = iter.list.map(self.data.cols, function(col)
        return border[11]:rep(col.width)
    end)
    local highlight = above and self.config.head or self.config.row
    return self:prefix_line(node)
        :text(chars[1] .. table.concat(parts, chars[2]) .. chars[3], highlight)
        :get()
end

---@private
function Render:render_virtual()
    local data = assert(self.virtual)
    local lines = {} ---@type render.md.mark.Line[]
    local rows = self.data.rows
    local first_prefix = self:prefix_line(rows[1].node):width()
    local last_prefix = self:prefix_line(rows[#rows].node):width()
    local full = self.config.border_enabled
        and self.data.layout.valid
        and first_prefix == last_prefix
    if full then
        lines[#lines + 1] = self:virtual_border(true)
    end
    for i, row in ipairs(rows) do
        lines[#lines + 1] = self:virtual_row(row)
        if i == 1 then
            lines[#lines + 1] = self:virtual_delimiter()
        end
    end
    if full and #rows > 1 then
        lines[#lines + 1] = self:virtual_border(false)
    end

    local conceal_range = { data.start_row, data.end_row }
    for row = data.start_row, data.end_row do
        local _, source = self.node:line('first', row - self.node.start_row)
        self.marks:add(self.config, true, row, 0, {
            end_row = row,
            end_col = #(source or ''),
            conceal_lines = '',
        }, conceal_range)
    end
    self.marks:add(self.config, true, data.anchor_row, 0, {
        virt_lines = lines,
        virt_lines_above = data.above,
    }, conceal_range)
end

---@protected
function Render:run()
    if self.virtual then
        self:render_virtual()
        return
    end
    self:delimiter()
    for _, row in ipairs(self.data.rows) do
        self:row(row)
    end
    if self.config.border_enabled and self.data.layout.valid then
        self:border()
    end
end

---@private
function Render:delimiter()
    local delim = self.data.delim
    local border = self.config.border
    local indicator = self.config.alignment_indicator

    local icon = border[11]
    local parts = iter.list.map(self.data.cols, function(col)
        -- must have enough space to put the alignment indicator
        -- alignment indicator must be exactly one character wide
        -- do not put an indicator for default alignment
        local add_indicator = col.width >= 3
            and str.width(indicator) == 1
            and col.alignment ~= Alignment.default
        if not add_indicator then
            return icon:rep(col.width)
        end
        if col.alignment == Alignment.left then
            return indicator .. icon:rep(col.width - 1)
        elseif col.alignment == Alignment.right then
            return icon:rep(col.width - 1) .. indicator
        else
            return indicator .. icon:rep(col.width - 2) .. indicator
        end
    end)
    local delimiter = border[4] .. table.concat(parts, border[5]) .. border[6]

    local line = self:line()
    line:pad(str.spaces('start', delim.text))
    line:text(delimiter, self.config.head)
    line:pad(str.width(delim.text) - line:width())
    self.marks:over(self.config, 'table_border', delim, {
        virt_text = line:get(),
        virt_text_pos = 'overlay',
    })
end

---@private
---@param row render.md.table.Row
function Render:row(row)
    local icon = self.config.border[10]
    local header = row.node.type == 'pipe_table_header'
    local highlight = header and self.config.head or self.config.row

    if vim.tbl_contains({ 'trimmed', 'padded', 'raw' }, self.config.cell) then
        for _, pipe in ipairs(row.pipes) do
            self.marks:over(self.config, 'table_border', pipe, {
                virt_text = { { icon, highlight } },
                virt_text_pos = 'overlay',
            })
        end
    end

    if vim.tbl_contains({ 'trimmed', 'padded' }, self.config.cell) then
        for i, cell in ipairs(row.cells) do
            local col = self.data.cols[i]
            local node = cell.node
            local space = cell.space
            local fill = col.width - cell.width
            -- delim(20) : --------------------
            -- col(4,7,2): ----XXXXXXX--
            -- fill(7)   :              _______
            if not self.context.conceal:enabled() then
                -- result: ----XXXXXXX--_______
                -- without concealing it is impossible to do full alignment
                self:shift(node, 'right', fill)
            elseif col.alignment == Alignment.center then
                -- (7 + 2 - 4) // 2 = 5 // 2 = 2 -> move two spaces to the right
                -- result: __----XXXXXXX--_____
                local shift = math.floor((fill + space.right - space.left) / 2)
                self:shift(node, 'left', shift)
                self:shift(node, 'right', fill - shift)
            elseif col.alignment == Alignment.right then
                -- 2 - 1 = 1 -> conceal one space on right side
                -- result: -_______----XXXXXXX-
                local shift = space.right - self.config.padding
                self:shift(node, 'left', fill + shift)
                self:shift(node, 'right', -shift)
            else
                -- 4 - 1 = 3 -> conceal three spaces on left side
                -- result: -XXXXXXX--_______---
                local shift = space.left - self.config.padding
                self:shift(node, 'left', -shift)
                self:shift(node, 'right', fill + shift)
            end
        end
    elseif self.config.cell == 'overlay' then
        self.marks:over(self.config, 'table_border', row.node, {
            virt_text = { { row.node.text:gsub('|', icon), highlight } },
            virt_text_pos = 'overlay',
        })
    end
end

---Use low priority to include pipe marks
---@private
---@param node render.md.Node
---@param side 'left'|'right'
---@param amount integer
function Render:shift(node, side, amount)
    local col = side == 'left' and node.start_col or node.end_col
    if amount > 0 then
        self.marks:add(self.config, true, node.start_row, col, {
            priority = 0,
            virt_text = self:line():pad(amount):get(),
            virt_text_pos = 'inline',
        })
    elseif amount < 0 then
        amount = amount - self.context.conceal:width('', 1)
        self.marks:add(self.config, true, node.start_row, col + amount, {
            priority = 0,
            end_col = col,
            conceal = '',
        })
    end
end

---@private
function Render:border()
    local rows = self.data.rows
    local border = self.config.border

    ---@param row render.md.table.Row
    ---@return boolean
    local function width_equal(row)
        if vim.tbl_contains({ 'trimmed', 'padded' }, self.config.cell) then
            -- assume table was modified to match
            return true
        elseif self.config.cell == 'raw' then
            -- want the computed widths to match
            for i, cell in ipairs(row.cells) do
                if cell.width ~= self.data.cols[i].width then
                    return false
                end
            end
            return true
        elseif self.config.cell == 'overlay' then
            -- want the underlying text widths to match
            return str.width(row.node.text) == str.width(self.data.delim.text)
        else
            return false
        end
    end

    local first = rows[1]
    local last = rows[#rows]
    if not width_equal(first) or not width_equal(last) then
        return
    end

    local icon = border[11]
    local parts = iter.list.map(self.data.cols, function(col)
        return icon:rep(col.width)
    end)

    ---@param node render.md.Node
    ---@param above boolean
    ---@param chars [string, string, string]
    local function table_border(node, above, chars)
        local text = chars[1] .. table.concat(parts, chars[2]) .. chars[3]
        local highlight = above and self.config.head or self.config.row
        local line = self:line():pad(self.data.layout.col):text(text, highlight)

        local virtual = self.config.border_virtual
        local row, target = node:line(above and 'above' or 'below', 1)
        local available = target and str.width(target) == 0

        if not virtual and available and self.context.used:take(row) then
            self.marks:add(self.config, 'table_border', row, 0, {
                virt_text = line:get(),
                virt_text_pos = 'overlay',
            })
        else
            self.marks:add(self.config, 'virtual_lines', node.start_row, 0, {
                virt_lines = { self:indent():line(true):extend(line):get() },
                virt_lines_above = above,
            })
        end
    end

    table_border(first.node, true, { border[1], border[2], border[3] })
    if #rows > 1 then
        table_border(last.node, false, { border[7], border[8], border[9] })
    end
end

return Render
