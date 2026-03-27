local group = vim.api.nvim_create_augroup('cloak', {})
local namespace = vim.api.nvim_create_namespace('cloak')

-- In case cmp is lazy loaded, we check :CmpStatus instead of a pcall to require
-- so we maintain the lazy load.
local has_cmp = function()
  return vim.fn.exists(':CmpStatus') > 0
end

local M = {}

M.opts = {
  enabled = true,
  cloak_character = '*',
  cloak_length = nil,
  highlight_group = 'Comment',
  try_all_patterns = true,
  patterns = { { file_pattern = '.env*', cloak_pattern = '=.+' } },
  cloak_telescope = true,
  cloak_snacks = false,
  cmp_exact = false,
  uncloaked_line_num = nil,
  cloak_on_leave = false,
  cloak_wrap = false,
}

M.setup = function(opts)
  M.opts = vim.tbl_deep_extend('force', M.opts, opts or {})
  vim.b.cloak_enabled = M.opts.enabled

  for _, pattern in ipairs(M.opts.patterns) do
    if type(pattern.cloak_pattern) == 'string' then
      pattern.cloak_pattern = { { pattern.cloak_pattern, replace = pattern.replace } }
    else
      for i, inner_pattern in ipairs(pattern.cloak_pattern) do
        pattern.cloak_pattern[i] =
          type(inner_pattern) == 'string'
            and { inner_pattern, replace = pattern.cloak_pattern.replace or pattern.replace }
            or inner_pattern
      end
    end

    vim.api.nvim_create_autocmd(
      { 'BufReadPost', 'BufNewFile', 'BufEnter', 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
        pattern = pattern.file_pattern,
        callback = function()
          if M.opts.enabled then
            M.cloak(pattern)
          else
            M.uncloak()
          end
        end,
        group = group,
      }
    )

    if M.opts.cloak_on_leave then
      vim.api.nvim_create_autocmd(
        'BufWinLeave', {
          pattern = pattern.file_pattern,
          callback = function()
            M.enable()
          end,
          group = group,
        }
      )
    end
  end

  if M.opts.cloak_snacks then
    vim.api.nvim_create_autocmd(
      'User', {
        pattern = 'SnacksPickerPreview',
        callback = function(args)
          if not M.opts.enabled or args.file == nil then
            return
          end

          local is_cloaked, _ = pcall(
            vim.api.nvim_buf_get_var, args.buf, 'cloaked'
          )

          if M.recloak_file(args.file) then
            vim.api.nvim_buf_set_var(args.buf, 'cloaked', true)
          end
        end,
        group = group,
      }
    )
  end

  if M.opts.cloak_telescope then
    vim.api.nvim_create_autocmd(
      'User', {
        pattern = 'TelescopePreviewerLoaded',
        callback = function(args)
          -- Feature not in 0.1.x
          if not M.opts.enabled or args.data == nil then
            return
          end

          local buffer = require('telescope.state').get_existing_prompt_bufnrs()[1]
          local picker = require('telescope.actions.state').get_current_picker(
            buffer
          )

          -- If our state variable is set, meaning we have just refreshed after cloaking a buffer,
          -- set the selection to that row again.
          if picker.__cloak_selection then
            picker:set_selection(picker.__cloak_selection)
            picker.__cloak_selection = nil
            vim.schedule(
              function()
                picker:refresh_previewer()
              end
            )
            return
          end

          local is_cloaked, _ = pcall(
            vim.api.nvim_buf_get_var, args.buf, 'cloaked'
          )

          -- Check the buffer agains all configured patterns,
          -- if matched, set a variable on the picker to know where we left off,
          -- set a buffer variable to know we already cloaked it later, and refresh.
          -- a refresh will result in the cloak being visible, and will make this
          -- aucmd be called again right away with the first result, which we will then
          -- set to what we have stored in the code above.
          if M.recloak_file(args.data.bufname) then
            vim.api.nvim_buf_set_var(args.buf, 'cloaked', true)
            if is_cloaked then
              return
            end

            local row = picker:get_selection_row()
            picker.__cloak_selection = row
            picker:refresh()
            return
          end
        end,
        group = group,
      }
    )
  end

  -- Handle cloaking the Telescope preview.

  vim.api.nvim_create_user_command('CloakEnable', M.enable, {})
  vim.api.nvim_create_user_command('CloakDisable', M.disable, {})
  vim.api.nvim_create_user_command('CloakToggle', M.toggle, {})
  vim.api.nvim_create_user_command('CloakPreviewLine', M.uncloak_line, {})
end

M.uncloak = function()
  vim.api.nvim_buf_clear_namespace(0, namespace, 0, -1)
end

M.uncloak_line = function()
  if not M.opts.enabled then
    return
  end

  local buf = vim.api.nvim_win_get_buf(0)
  local cursor = vim.api.nvim_win_get_cursor(0)
  M.opts.uncloaked_line_num = cursor[1]

  local preview_group = vim.api.nvim_create_augroup('cloak_preview_line', { clear = true })

  vim.api.nvim_create_autocmd(
    { 'CursorMoved', 'CursorMovedI', 'BufLeave' }, {
      buffer = buf,
      callback = function(args)
        if not M.opts.enabled then
          M.opts.uncloaked_line_num = nil
          pcall(vim.api.nvim_del_augroup_by_id, preview_group)
          return true
        end

        if args.event == 'BufLeave' then
          M.opts.uncloaked_line_num = nil
          M.recloak_file(vim.api.nvim_buf_get_name(buf))
          pcall(vim.api.nvim_del_augroup_by_id, preview_group)
          return true
        end

        local ncursor = vim.api.nvim_win_get_cursor(0)
        if ncursor[1] == M.opts.uncloaked_line_num then
          return
        end

        M.opts.uncloaked_line_num = nil
        M.recloak_file(vim.api.nvim_buf_get_name(buf))
        pcall(vim.api.nvim_del_augroup_by_id, preview_group)
        return true
      end,
      group = preview_group,
    }
  )

  M.recloak_file(vim.api.nvim_buf_get_name(buf))
end

M.cloak = function(pattern)
  M.uncloak()

  if has_cmp() and M.opts.cmp_exact ~= true then
    require('cmp').setup.buffer({ enabled = false })
  end

  local function determine_replacement(length, prefix)
    local cloak_str = prefix
      .. M.opts.cloak_character:rep(
        tonumber(M.opts.cloak_length)
        or length - vim.fn.strchars(prefix))
    local remaining_length = length - vim.fn.strchars(cloak_str)
    return cloak_str
      .. (' '):rep(math.max(0, remaining_length))
  end

  local function place_extmark(row_0idx, col_0idx, end_col_0idx_excl, length, prefix)
    if M.opts.cloak_wrap and vim.fn.has('nvim-0.10') == 1 then
      vim.opt_local.conceallevel = 2
      local replacement = prefix .. M.opts.cloak_character:rep(tonumber(M.opts.cloak_length) or length)
      pcall(vim.api.nvim_buf_set_extmark, 0, namespace, row_0idx, col_0idx, {
        hl_mode = 'combine',
        virt_text = { { replacement, M.opts.highlight_group } },
        virt_text_pos = 'inline',
        conceal = '', -- Hides the actual text underneath
        end_col = end_col_0idx_excl,
      })
    else
      local replacement = determine_replacement(length, prefix)
      pcall(vim.api.nvim_buf_set_extmark, 0, namespace, row_0idx, col_0idx, {
        hl_mode = 'combine',
        virt_text = { { replacement, M.opts.highlight_group } },
        virt_text_pos = 'overlay',
      })
    end
  end

  local found_pattern = false
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if #lines == 0 then return end

  if pattern.multiline then
    -- Full-buffer engine for explicit multi-line patterns (e.g. PEM keys).
    -- Patterns must use [^\n] instead of . if you don't want cross-line matching.
    local full_text = table.concat(lines, '\n')
    local line_starts = { 1 }
    local cur = 1
    for i = 1, #lines - 1 do
      cur = cur + #lines[i] + 1
      table.insert(line_starts, cur)
    end
    local function byte_to_pos(offset)
      for i = #line_starts, 1, -1 do
        if offset >= line_starts[i] then
          return i, offset - line_starts[i] + 1
        end
      end
      return 1, 1
    end

    local si = 1
    while si <= #full_text do
      local first, last, matching_pattern, has_groups = -1, 1, nil, false
      for _, ip in ipairs(pattern.cloak_pattern) do
        local cf, cl, cg = full_text:find(ip[1], si)
        if cf ~= nil and (first < 0 or cf < first or (cf == first and cl > last)) then
          first, last, matching_pattern, has_groups = cf, cl, ip, cg ~= nil
          if M.opts.try_all_patterns == false then break end
        end
      end
      if first < 0 then break end
      found_pattern = true

      local match_str = full_text:sub(first, last)
      local prefix = match_str:sub(1, 1)
      if has_groups and matching_pattern.replace ~= nil then
        prefix = match_str:gsub(matching_pattern[1], matching_pattern.replace, 1)
      end
      local prefix_len = #prefix
      if prefix == full_text:sub(first, first + prefix_len - 1) then
        first = first + prefix_len
        prefix = ''
      end

      if first <= last then
        local sr, sc = byte_to_pos(first)
        local er, ec = byte_to_pos(last)
        for i = sr, er do
          if i ~= M.opts.uncloaked_line_num then
            local l_start = (i == sr) and sc or 1
            local l_end   = (i == er) and ec or #lines[i]
            if l_end >= l_start then
              local len = l_end - l_start + 1
              place_extmark(i - 1, l_start - 1, l_end, len, prefix)
              prefix = ''
            end
          end
        end
      end
      si = last + 1
    end

  else
    -- Original line-by-line engine (Lua's `.` would match \n in full-text mode,
    -- so we keep per-line matching to preserve correct single-line behaviour).
    for i, line in ipairs(lines) do
      local si = 1
      while si < #line and i ~= M.opts.uncloaked_line_num do
        local first, last, matching_pattern, has_groups = -1, 1, nil, false
        for _, ip in ipairs(pattern.cloak_pattern) do
          local cf, cl, cg = line:find(ip[1], si)
          if cf ~= nil and (first < 0 or cf < first or (cf == first and cl > last)) then
            first, last, matching_pattern, has_groups = cf, cl, ip, cg ~= nil
            if M.opts.try_all_patterns == false then break end
          end
        end
        if first < 0 then break end
        found_pattern = true

        local prefix = line:sub(first, first)
        if has_groups and matching_pattern.replace ~= nil then
          prefix = line:sub(first, last):gsub(matching_pattern[1], matching_pattern.replace, 1)
        end
        local last_of_prefix = first + vim.fn.strchars(prefix) - 1
        if prefix == line:sub(first, last_of_prefix) then
          first, prefix = last_of_prefix + 1, ''
        end

        place_extmark(i - 1, first - 1, last, last - first + 1, prefix)
        si = last
      end
    end
  end

  if found_pattern then
    if not (M.opts.cloak_wrap and vim.fn.has('nvim-0.10') == 1) then
      vim.opt_local.wrap = false
    end
  end
end


M.recloak_file = function(filename)
  local base_name = vim.fn.fnamemodify(filename, ':t')
  for _, pattern in ipairs(M.opts.patterns) do
    -- Could be a string or a table of patterns.
    local file_patterns = pattern.file_pattern
    if type(file_patterns) == 'string' then
      file_patterns = { file_patterns }
    end

    for _, file_pattern in ipairs(file_patterns) do
      if base_name ~= nil and
        vim.fn.match(base_name, vim.fn.glob2regpat(file_pattern)) ~= -1 then
        M.cloak(pattern)
        return true
      end
    end
  end

  return false
end

M.disable = function()
  M.uncloak()
  M.opts.enabled = false
  vim.b.cloak_enabled = false
  M.opts.uncloaked_line_num = nil
end

M.enable = function()
  M.opts.enabled = true
  vim.b.cloak_enabled = true
  vim.cmd('doautocmd TextChanged')
end

M.toggle = function()
  if M.opts.enabled then
    M.disable()
  else
    M.enable()
  end
end

return M
