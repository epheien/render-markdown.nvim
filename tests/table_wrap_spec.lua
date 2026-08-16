---@module 'luassert'

local util = require('tests.util')

describe('table_wrap.md', function()
    ---@return vim.api.keyset.extmark_details[]
    local function extmark_details()
        local namespace = require('render-markdown.core.ui').ns
        local marks = vim.api.nvim_buf_get_extmarks(
            0,
            namespace,
            0,
            -1,
            { details = true }
        )
        return vim.tbl_map(function(mark)
            return mark[4]
        end, marks)
    end

    ---@return { [1]: string, [2]: string|string[] }[][]
    local function virtual_tables()
        local result = {}
        for _, details in ipairs(extmark_details()) do
            if details.virt_lines ~= nil and #details.virt_lines > 2 then
                table.insert(result, details.virt_lines)
            end
        end
        return result
    end

    ---@return boolean
    local function has_virtual_table()
        for _, details in ipairs(extmark_details()) do
            if details.conceal_lines ~= nil then
                return true
            end
        end
        return false
    end

    ---@param callback function
    local function run_scheduled(callback)
        -- Plenary runs this spec inside a headless startup callback, where nested waits cannot flush
        -- vim.schedule. Capture one scheduling layer so OptionSet can be tested deterministically.
        local scheduled, original = {}, vim.schedule
        vim.schedule = function(value)
            table.insert(scheduled, value)
        end
        local ok, err = pcall(callback)
        vim.schedule = original
        if not ok then
            error(err, 0)
        end
        for _, value in ipairs(scheduled) do
            value()
        end
    end

    local function render_now()
        run_scheduled(function()
            local buf, win =
                vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
            require('render-markdown.core.ui').update(buf, win, 'Test', true)
        end)
    end

    ---@param value boolean
    local function set_wrap(value)
        run_scheduled(function()
            vim.wo.wrap = value
            -- OptionSet is suppressed while headless startup commands are running.
            vim.api.nvim_exec_autocmds('OptionSet', { pattern = 'wrap' })
        end)
    end

    ---@param line { [1]: string, [2]: string|string[] }[]
    ---@return string
    local function line_text(line)
        local result = ''
        for _, part in ipairs(line) do
            result = result .. part[1]
        end
        return result
    end

    ---@param lines { [1]: string, [2]: string|string[] }[][]
    ---@param value string
    ---@return { [1]: string, [2]: string|string[] }[]
    local function find_line(lines, value)
        for _, line in ipairs(lines) do
            if line_text(line):find(value, 1, true) ~= nil then
                return line
            end
        end
        error('missing virtual line containing: ' .. value)
    end

    ---@param line { [1]: string, [2]: string|string[] }[]
    ---@param value string
    ---@return string|string[]
    local function find_highlight(line, value)
        for _, part in ipairs(line) do
            if part[1]:find(value, 1, true) ~= nil then
                return part[2]
            end
        end
        error('missing virtual text containing: ' .. value)
    end

    local screen = {
        '󰫎   1 󰲡 Table with Long Source',
        '    2',
        '      ┌──────┬────────┐',
        '      │ Kind │ Asset  │',
        '      ├──────┼────────┤',
        '      │ Icon │ 󰊤 tiny │',
        '      └──────┴────────┘',
        '    6',
        '    7 After table.',
    }

    local nowrap_screen = {
        '󰫎   1 󰲡 Table with Long Source',
        '    2 ┌──────┬────────┐',
        '    3 │ Kind │ Asset  │',
        '    4 ├──────┼────────┤',
        '    5 │ Icon │ 󰊤 tiny │',
        '    6 └──────┴────────┘',
        '    7 After table.',
    }

    it(
        'does not keep wraps from concealed source text and updates with wrap',
        function()
            if vim.fn.has('nvim-0.11') == 0 then
                return
            end
            vim.wo.number = true
            vim.wo.wrap = true
            util.setup.file('tests/data/table_wrap.md', { debounce = 0 })
            render_now()

            assert.is_true(vim.wo.wrap)
            assert.is_true(has_virtual_table())
            util.assert_screen(screen)

            set_wrap(false)
            assert.is_false(has_virtual_table())
            util.assert_screen(nowrap_screen)

            set_wrap(true)
            assert.is_true(has_virtual_table())

            util.assert_screen(screen)
        end
    )

    it('preserves rendered content and tree-sitter highlights', function()
        if vim.fn.has('nvim-0.11') == 0 then
            return
        end
        vim.wo.wrap = true
        util.setup.file('tests/data/table_wrap_content.md', { debounce = 0 })
        render_now()

        local tables = virtual_tables()
        assert.are.same(1, #tables)
        local image = find_line(tables[1], '󰊤')
        assert.are.same('RenderMarkdownLink', find_highlight(image, '󰊤'))

        local style = find_line(tables[1], 'bold')
        assert.are.same('@markup.strong', find_highlight(style, 'bold'))
        assert.are.same('@markup.italic', find_highlight(style, 'italic'))
        assert.are.same(
            '@markup.strikethrough',
            find_highlight(style, 'strike')
        )
    end)

    it('preserves quote and section prefixes', function()
        if vim.fn.has('nvim-0.11') == 0 then
            return
        end
        vim.wo.wrap = true
        util.setup.file('tests/data/table_wrap_prefix.md', {
            debounce = 0,
            indent = { enabled = true },
        })
        render_now()

        local tables = virtual_tables()
        assert.are.same(2, #tables)

        local quote_header = find_line(tables[1], 'Kind')
        local quote_delimiter = find_line(tables[1], '├')
        local quote_border = find_line(tables[1], '┌')
        assert.is_true(vim.startswith(line_text(quote_border), '▋ ┌'))
        assert.is_true(vim.startswith(line_text(quote_header), '▋ │'))
        assert.is_true(vim.startswith(line_text(quote_delimiter), '▋ ├'))

        local indent_header = find_line(tables[2], 'Kind')
        local indent_delimiter = find_line(tables[2], '├')
        local indent_border = find_line(tables[2], '┌')
        assert.is_true(vim.startswith(line_text(indent_border), '▎ ┌'))
        assert.is_true(vim.startswith(line_text(indent_header), '▎ │'))
        assert.is_true(vim.startswith(line_text(indent_delimiter), '▎ ├'))
    end)
end)
