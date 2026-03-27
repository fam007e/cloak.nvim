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

  local found_pattern = false
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if #lines == 0 then return end
  
  local full_text = table.concat(lines, '\n')
  local line_starts = { 1 }
  local current_offset = 1
  for i = 1, #lines - 1 do
    current_offset = current_offset + #lines[i] + 1 -- +1 for '\n'
    table.insert(line_starts, current_offset)
  end

  local function byte_to_pos(offset)
    for i = #line_starts, 1, -1 do
      if offset >= line_starts[i] then
        return i, offset - line_starts[i] + 1
      end
    end
    return 1, 1
  end

  -- Find all matches for the current buffer text
  local searchStartIndex = 1
  while searchStartIndex <= #full_text do
    local first, last, matching_pattern, has_groups = -1, 1, nil, false
    for _, inner_pattern in ipairs(pattern.cloak_pattern) do
      local current_first, current_last, capture_group =
        full_text:find(inner_pattern[1], searchStartIndex)
      if current_first ~= nil
        and (first < 0
          or current_first < first
          or (current_first == first and current_last > last)) then
        first, last, matching_pattern, has_groups =
          current_first, current_last, inner_pattern, capture_group ~= nil
        if M.opts.try_all_patterns == false then break end
      end
    end

    if first >= 0 then
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
        local start_row, start_col = byte_to_pos(first)
        local end_row, end_col = byte_to_pos(last)
        local virt_text_pos = vim.fn.has('nvim-0.10') == 1 and 'inline' or 'overlay'

        for i = start_row, end_row do
          if i ~= M.opts.uncloaked_line_num then
            local l_start = (i == start_row) and start_col or 1
            local l_end = (i == end_row) and end_col or (#lines[i])
            if l_end >= l_start then
              local line_match_len = l_end - l_start + 1
              local replacement = virt_text_pos == 'inline'
                and (prefix .. M.opts.cloak_character:rep(tonumber(M.opts.cloak_length) or line_match_len))
                or determine_replacement(line_match_len, prefix)
              
              prefix = '' -- Only apply prefix to the first line's payload
              
              local extmark_opts = {
                hl_mode = 'combine',
                virt_text = { { replacement, M.opts.highlight_group } },
                virt_text_pos = virt_text_pos,
              }
              if virt_text_pos == 'inline' then
                extmark_opts.end_col = l_end
              end
              
              pcall(vim.api.nvim_buf_set_extmark,
                0, namespace, i - 1, l_start - 1, extmark_opts
              )
            end
          end
        end
      end
      searchStartIndex = last + 1
    else
      break
    end
  end

  if found_pattern then
    if vim.fn.has('nvim-0.10') == 0 then
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
