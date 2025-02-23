local util = require "codeql.util"
local config = require "codeql.config"
local Popup = require "nui.popup"
local autocmd = require "nui.utils.autocmd"
local event = autocmd.event

local range_ns = vim.api.nvim_create_namespace "codeql"
local panel_buffer_name = "__CodeQLPanel__"
local panel_pos = "right"
local panel_width = 50
local panel_short_help = true
local icon_closed = "▶"
local icon_open = "▼"

-- global variables
local M = {}

M.scan_results = {}
M.line_map = {}

local function generate_issue_label(node)
  local label = node.label
  local conf = config.get_config()
  if conf.panel.show_filename and node["filename"] and node["filename"] ~= nil then
    if conf.panel.long_filename then
      label = node.filename
    elseif #vim.fn.fnamemodify(node.filename, ":p:t") > 0 then
      label = vim.fn.fnamemodify(node.filename, ":p:t")
    else
      label = node.label
    end
    if node.line and node.line > 0 then
      label = label .. ":" .. node.line
    end
  end
  return label
end

local function register(obj)
  local bufnr = vim.fn.bufnr(panel_buffer_name)
  local curline = vim.api.nvim_buf_line_count(bufnr)
  M.line_map[curline] = obj
end

local function print_to_panel(text, matches)
  local bufnr = vim.fn.bufnr(panel_buffer_name)

  local lines = vim.split(text, "\n")
  text = table.concat(lines, " <CR> ")

  vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { text })
  if type(matches) == "table" then
    for hlgroup, groups in pairs(matches) do
      for _, group in ipairs(groups) do
        local linenr = vim.api.nvim_buf_line_count(bufnr) - 1
        vim.api.nvim_buf_add_highlight(bufnr, 0, hlgroup, linenr, group[1], group[2])
      end
    end
  end
end

local function get_panel_window(buffer_name)
  local bufnr = vim.fn.bufnr(buffer_name)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      return w
    end
  end
  return nil
end

local function go_to_main_window()
  -- go to the wider window
  local widerwin = 0
  local widerwidth = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_width(w) > widerwidth then
      if vim.api.nvim_win_get_buf(w) ~= vim.fn.bufnr(panel_buffer_name) then
        widerwin = w
        widerwidth = vim.api.nvim_win_get_width(w)
      end
    end
  end
  if widerwin > -1 then
    vim.fn.win_gotoid(widerwin)
  end
end

local function is_filtered(filter, issue)
  local f, err = loadstring("return function(issue) return " .. filter .. " end")
  if f then
    return f()(issue)
  else
    return f, err
  end
end

local function print_help()
  if panel_short_help then
    print_to_panel '" Press H for help'
    print_to_panel ""
  else
    print_to_panel '" --------- General ---------'
    print_to_panel '" <CR>: Jump to tag definition'
    print_to_panel '" p: As above, but dont change window'
    print_to_panel '" P: Previous path'
    print_to_panel '" N: Next path'
    print_to_panel '"'
    print_to_panel '" ---------- Folds ----------'
    print_to_panel '" f: Label filter'
    print_to_panel '" F: Generic filter'
    print_to_panel '" x: Clear filter'
    print_to_panel '"'
    print_to_panel '" ---------- Folds ----------'
    print_to_panel '" o: Toggle fold'
    print_to_panel '" O: Open all folds'
    print_to_panel '" C: Close all folds'
    print_to_panel '"'
    print_to_panel '" ---------- Misc -----------'
    print_to_panel '" m: Toggle mode'
    print_to_panel '" q: Close window'
    print_to_panel '" H: Toggle help'
    print_to_panel ""
  end
end

local function get_node_location(node)
  if node.line and node.filename then
    local line = ""
    if node.line > -1 then
      line = string.format(":%d", node.line)
    end
    local filename
    local conf = config.get_config()
    if conf.panel.long_filename then
      filename = node.filename
    else
      filename = vim.fn.fnamemodify(node.filename, ":p:t")
    end
    return filename .. line
  else
    return ""
  end
end

local function print_tree_node(node, indent_level)
  local text = ""
  local hl = {}

  -- mark
  local mark = string.rep(" ", indent_level) .. node.mark .. " "
  local mark_hl_name = ""
  if node.mark == "≔" then
    mark_hl_name = "CodeqlPanelLabel"
  else
    mark_hl_name = node.visitable and "CodeqlPanelVisitable" or "CodeqlPanelNonVisitable"
  end
  hl[mark_hl_name] = { { 0, string.len(mark) } }

  -- text
  if node.filename then
    local location = get_node_location(node)
    text = string.format("%s%s - %s", mark, location, node.label)

    local sep_index = string.find(text, " - ", 1, true)

    hl["CodeqlPanelFile"] = { { string.len(mark), sep_index } }
    hl["CodeqlPanelSeparator"] = { { sep_index, sep_index + 2 } }
  else
    text = mark .. "[" .. node.label .. "]"
  end
  print_to_panel(text, hl)

  register {
    kind = "node",
    obj = node,
  }
end

local function right_align(text, size)
  return string.rep(" ", size - vim.fn.strdisplaywidth(text)) .. text
end

local function center_align(text, size)
  local pad = size - vim.fn.strdisplaywidth(text)
  local left_pad = math.floor(pad / 2)
  local right_pad = pad - left_pad
  return string.rep(" ", left_pad) .. text .. string.rep(" ", right_pad)
end

local function get_table_nodes(issue, max_lengths)
  local path = issue.paths[1]
  local labels = {}
  local locations = {}
  for i, node in ipairs(path) do
    table.insert(labels, center_align(node.label, max_lengths[i]))
    table.insert(locations, center_align(get_node_location(node), max_lengths[i]))
  end
  return { labels, locations }
end

local function print_tree_nodes(issue, indent_level)
  local bufnr = vim.fn.bufnr(panel_buffer_name)
  local curline = vim.api.nvim_buf_line_count(bufnr)

  local paths = issue.paths

  -- paths
  local active_path = 1
  if #paths > 1 then
    if M.line_map[curline] and M.line_map[curline].kind == "issue" then
      -- retrieve path info from the line_map
      active_path = M.line_map[curline].obj.active_path
    end
    local str = active_path .. "/" .. #paths
    if M.line_map[curline + 1] then
      table.remove(M.line_map, curline + 1)
    end
    local text = string.rep(" ", indent_level) .. "Path: "
    local hl = { CodeqlPanelInfo = { { 0, string.len(text) } } }
    print_to_panel(text .. str, hl)
    register(nil)
  end
  local path = paths[active_path]

  --  print path nodes
  for _, node in ipairs(path) do
    print_tree_node(node, indent_level)
  end
end

local function print_header(scan_results)
  if config.database.path then
    local hl = { CodeqlPanelInfo = { { 0, string.len "Database:" } } }
    print_to_panel("Database: " .. config.database.path, hl)
  elseif config.sarif.path then
    local hl = { CodeqlPanelInfo = { { 0, string.len "SARIF:" } } }
    print_to_panel("SARIF: " .. config.sarif.path, hl)
  end
  local hl = { CodeqlPanelInfo = { { 0, string.len "Issues:" } } }
  print_to_panel("Issues:   " .. table.getn(scan_results.issues), hl)
end

local function get_column_names(columns, max_lengths)
  local result = {}
  for i, column in ipairs(columns) do
    table.insert(result, center_align(column, max_lengths[i]))
  end
  return result
end

local function print_issues(results)
  if results.mode == "tree" then
    -- print group name
    local rule_foldmarker = not results.is_folded and icon_open or icon_closed
    local rule_label = string.format("%s %s", rule_foldmarker, results.label)

    print_to_panel(string.format("%s (%d)", rule_label, #results.issues), {
      CodeqlPanelFoldIcon = { { 0, string.len(rule_foldmarker) } },
      CodeqlPanelRuleId = { { string.len(rule_foldmarker), string.len(rule_label) } },
    })
    register {
      kind = "rule",
      obj = results,
    }

    if not results.is_folded then
      -- print issue labels
      for _, issue in ipairs(results.issues) do
        -- print nodes
        if not issue.hidden then
          local is_folded = issue.is_folded
          local foldmarker = not is_folded and icon_open or icon_closed
          local label = string.format("  %s %s", foldmarker, generate_issue_label(issue.node))
          print_to_panel(label, {
            CodeqlPanelFoldIcon = { { 0, 2 + string.len(foldmarker) } },
            --CodeqlPanelRuleId = { { 2 + string.len(foldmarker), string.len(label) } },
          })

          register {
            kind = "issue",
            obj = issue,
          }

          if not is_folded then
            print_tree_nodes(issue, 4)
          end
        end
      end
    end
  elseif results.mode == "table" then
    -- TODO: node.label may need to be tweaked (eg: replace new lines with "")
    -- and this is the place to do it

    -- calculate max length for each cell
    local max_lengths = {}
    for _, issue in ipairs(results.issues) do
      local path = issue.paths[1]
      for i, node in ipairs(path) do
        max_lengths[i] = math.max(vim.fn.strdisplaywidth(node.label), max_lengths[i] or -1)
        max_lengths[i] = math.max(vim.fn.strdisplaywidth(get_node_location(node)), max_lengths[i] or -1)
      end
    end
    if results.columns and #results.columns > 0 then
      for i, column in ipairs(results.columns) do
        max_lengths[i] = math.max(vim.fn.strdisplaywidth(column), max_lengths[i] or -1)
      end
    end

    local total_length = 4
    for _, len in ipairs(max_lengths) do
      total_length = total_length + len + 3
    end
    print_to_panel ""

    local rows = {}
    for _, issue in ipairs(results.issues) do
      table.insert(rows, get_table_nodes(issue, max_lengths))
    end

    local bars = {}
    for _, len in ipairs(max_lengths) do
      table.insert(bars, string.rep("─", len))
    end

    local column_names = get_column_names(results.columns, max_lengths)

    local header1 = string.format("┌─%s─┐", table.concat(bars, "─┬─"))
    print_to_panel(header1, { CodeqlPanelSeparator = { { 0, -1 } } })
    if results.columns and #results.columns > 0 then
      local header2 = string.format("│ %s │", table.concat(column_names, " │ "))
      print_to_panel(header2, { CodeqlPanelSeparator = { { 0, -1 } } })
      local header3 = string.format("├─%s─┤", table.concat(bars, "─┼─"))
      print_to_panel(header3, { CodeqlPanelSeparator = { { 0, -1 } } })
    end

    local separator_hls = { { 0, vim.fn.len "│ " } }
    local acc = vim.fn.len "│ "
    for _, len in ipairs(max_lengths) do
      table.insert(separator_hls, { acc + len, acc + len + vim.fn.len " │ " })
      acc = acc + len + vim.fn.len " │ "
    end

    local location_hls = {}
    acc = vim.fn.len "│ "
    for _, len in ipairs(max_lengths) do
      table.insert(location_hls, { acc, acc + len })
      acc = acc + len + vim.fn.len " │ "
    end

    local hl_labels = { CodeqlPanelSeparator = separator_hls }
    local hl_locations = { CodeqlPanelSeparator = separator_hls, Comment = location_hls }
    for i, row in ipairs(rows) do
      -- labels
      local r = string.format("│ %s │", table.concat(row[1], " │ "))
      print_to_panel(r, hl_labels)
      register {
        kind = "row",
        obj = {
          ranges = location_hls,
          columns = results.issues[i].paths[1],
        },
      }

      -- locations
      r = string.format("│ %s │", table.concat(row[2], " │ "))
      print_to_panel(r, hl_locations)
      register {
        kind = "row",
        obj = {
          ranges = location_hls,
          columns = results.issues[i].paths[1],
        },
      }

      if i < #rows then
        r = string.format("├─%s─┤", table.concat(bars, "─┼─"))
        print_to_panel(r, { CodeqlPanelSeparator = { { 0, -1 } } })
      end
    end
    local footer = string.format("└─%s─┘", table.concat(bars, "─┴─"))
    print_to_panel(footer, { CodeqlPanelSeparator = { { 0, -1 } } })
  end
end

local function render_content(scan_results)
  local bufnr = vim.fn.bufnr(panel_buffer_name)
  if bufnr == -1 then
    util.err_message "Error opening CodeQL panel"
    return
  end

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

  print_help()

  if #scan_results.issues > 0 then
    print_header(scan_results)
    print_to_panel ""
    for _, rule in ipairs(scan_results.rules) do
      print_issues(rule)
    end

    local win = get_panel_window(panel_buffer_name)
    local lcount = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_win_set_cursor(win, { math.min(7, lcount), 0 })
  else
    print_to_panel "No results found."
  end
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  util.message " "
end

local function render_keep_view(line)
  if line == nil then
    line = vim.fn.line "."
  end

  -- called from toggle_fold commands, so within panel buffer
  local curcol = vim.fn.col "."
  local topline = vim.fn.line "w0"

  render_content(M.scan_results)

  local scrolloff_save = vim.api.nvim_get_option "scrolloff"
  vim.cmd "set scrolloff=0"

  vim.fn.cursor(topline, 1)
  vim.cmd "normal! zt"
  vim.fn.cursor(line, curcol)

  vim.cmd("let &scrolloff = " .. scrolloff_save)
  vim.cmd "redraw"
end

-- exported functions

function M.apply_mappings()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "o",
    [[<cmd>lua require'codeql.panel'.toggle_fold()<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "m",
    [[<cmd>lua require'codeql.panel'.toggle_mode()<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "<CR>",
    [[<cmd>lua require'codeql.panel'.jump_to_code(false)<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "p",
    [[<cmd>lua require'codeql.panel'.jump_to_code(true)<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "s",
    [[<cmd>lua require'codeql.panel'.preview_snippet(true)<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "<S-h>",
    [[<cmd>lua require'codeql.panel'.toggle_help()<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "q",
    [[<cmd>lua require'codeql.panel'.close_panel()<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "<S-o>",
    [[<cmd>lua require'codeql.panel'.set_fold_level(false)<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "<S-c>",
    [[<cmd>lua require'codeql.panel'.set_fold_level(true)<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "<S-p>",
    [[<cmd>lua require'codeql.panel'.change_path(-1)<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "N",
    [[<cmd>lua require'codeql.panel'.change_path(1)<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "f",
    [[<cmd>lua require'codeql.panel'.label_filter()<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "<S-f>",
    [[<cmd>lua require'codeql.panel'.generic_filter()<CR>]],
    { script = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    bufnr,
    "n",
    "<S-x`>",
    [[<cmd>lua require'codeql.panel'.clear_filter()<CR>]],
    { script = true, silent = true }
  )
end

local function unhide_issues(issues)
  for _, issue in ipairs(issues) do
    issue.hidden = false
  end
end

local function filter_issues(issues, filter_str)
  for _, issue in ipairs(issues) do
    if not is_filtered(filter_str, issue) then
      issue.hidden = true
    end
  end
end

function M.clear_filter()
  unhide_issues(M.scan_results.issues)
  render_content(M.scan_results)
end

function M.label_filter()
  local pattern = vim.fn.input "Pattern: "
  unhide_issues(M.scan_results.issues)
  filter_issues(
    M.scan_results.issues,
    string.format("string.match(string.lower(generate_issue_label(issue.node)), string.lower('%s')) ~= nil", pattern)
  )
  render_content(M.scan_results)
end

function M.generic_filter()
  local pattern = vim.fn.input "Pattern: "
  unhide_issues(M.scan_results.issues)
  filter_issues(M.scan_results.issues, pattern)
  render_content(M.scan_results)
end

function M.toggle_mode()
  if M.scan_results.mode == "tree" then
    M.scan_results.mode = "table"
  elseif M.scan_results.mode == "table" then
    M.scan_results.mode = "tree"
  end
  M.render(M.scan_results.issues, {
    kind = M.scan_results.kind,
    mode = M.scan_results.mode,
    columns = M.scan_results.columns,
  })
end

local function get_enclosing_issue(line)
  local entry
  while line >= 7 do
    entry = M.line_map[line]
    if
      entry
      and (entry.kind == "node" or entry.kind == "issue" or entry.kind == "rule")
      and vim.tbl_contains(vim.tbl_keys(entry.obj), "is_folded")
    then
      return entry.obj
    end
    line = line - 1
  end
end

function M.toggle_fold()
  -- prevent highlighting from being off after adding/removing the help text
  vim.cmd "match none"

  local line = vim.fn.line "."
  local issue = get_enclosing_issue(line)
  if vim.tbl_contains(vim.tbl_keys(issue), "is_folded") then
    issue.is_folded = not issue.is_folded
    render_keep_view(line)
  end
end

function M.toggle_help()
  panel_short_help = not panel_short_help
  -- prevent highlighting from being off after adding/removing the help text
  render_keep_view()
end

function M.set_fold_level(level)
  for k, _ in pairs(M.line_map) do
    M.line_map[k].obj.is_folded = level
  end
  render_keep_view()
end

function M.change_path(offset)
  local line = vim.fn.line "."
  local issue = get_enclosing_issue(line)

  if issue.active_path then
    if issue.active_path == 1 and offset == -1 then
      issue.active_path = #issue.paths
    elseif issue.active_path == #issue.paths and offset == 1 then
      issue.active_path = 1
    else
      issue.active_path = issue.active_path + offset
    end
    render_keep_view(line + 1)
  end
end

local function get_column_at_cursor(row)
  local ranges = row.ranges
  local cur = vim.api.nvim_win_get_cursor(0)
  for i, range in ipairs(ranges) do
    if tonumber(range[1]) <= tonumber(cur[2]) and tonumber(cur[2]) <= tonumber(range[2]) then
      return row.columns[i]
    end
  end
end

local function get_current_node()
  if not M.line_map[vim.fn.line "."] then
    return
  end

  local node
  local entry = M.line_map[vim.fn.line "."]
  if entry.kind == "issue" then
    node = entry.obj.node
  elseif entry.kind == "node" then
    node = entry.obj
  elseif entry.kind == "row" then
    node = get_column_at_cursor(entry.obj)
  end
  return node
end

function M.jump_to_code(stay_in_panel)
  local node = get_current_node()
  if not node or not node.visitable then
    return
  end

  -- open from ZIP archive or SARIF file
  if
    (config.database.sourceArchiveZip and util.is_file(config.database.sourceArchiveZip))
    or (config.sarif.path and util.is_file(config.sarif.path) and config.sarif.hasArtifacts)
  then
    if string.sub(node.filename, 1, 1) == "/" then
      node.filename = string.sub(node.filename, 2)
    end

    -- save audit pane window
    local panel_winid = vim.fn.win_getid()

    -- hide windline if installed
    local ok, fl = pcall(require, "wlfloatline")
    if ok then
      fl.floatline_hide()
    end

    -- choose the target window to open the file in
    local target_id = util.pick_window(panel_winid)

    -- restore windline if needed
    if ok then
      fl.floatline_on_resize()
    end

    -- go to the target window
    vim.fn.win_gotoid(target_id)

    -- create the codeql:// buffer
    local bufname = string.format("codeql://%s", node.filename)
    if vim.fn.bufnr(bufname) == -1 then
      vim.api.nvim_command(string.format("edit %s", bufname))
    else
      vim.api.nvim_command(string.format("buffer %s", bufname))
    end

    -- move cursor to the node's line
    pcall(vim.api.nvim_win_set_cursor, 0, { node.line, 0 })
    vim.cmd "norm! zz"

    -- highlight node
    vim.api.nvim_buf_clear_namespace(0, range_ns, 0, -1)
    local startLine = node.url.startLine
    local startColumn = node.url.startColumn
    local endColumn = node.url.endColumn
    pcall(vim.api.nvim_buf_add_highlight, 0, range_ns, "CodeqlRange", startLine - 1, startColumn - 1, endColumn)

    -- jump to main window if requested
    if stay_in_panel then
      vim.fn.win_gotoid(panel_winid)
    end
  else
    util.err_message("Cannot find source code for " .. node.filename)
  end
end

function M.preview_snippet()
  local node = get_current_node()
  if not node or not node.visitable then
    return
  end
  local conf = config.get_config()
  local context_lines = conf.panel.context_lines
  local snippet = {}
  local max_len = 0
  local context_start_line
  if config.sarif.path and node.contextRegion and node.contextRegion.snippet then
    snippet = vim.split(node.contextRegion.snippet.text, "\n")
    context_start_line = node.contextRegion.startLine
    for _, line in ipairs(snippet) do
      if #line > max_len then
        max_len = #line
      end
    end
  elseif config.sarif.path and config.sarif.hasArtifacts then
    local sarif = util.read_json_file(config.sarif.path)
    local artifacts = sarif.runs[1].artifacts
    for _, artifact in ipairs(artifacts) do
      local uri = "/" .. util.uri_to_fname(artifact.location.uri)
      if uri == node.filename then
        local content = vim.split(artifact.contents.text, "\n")
        context_start_line = math.max(node.url.startLine - context_lines, 0)
        local context_end_line = math.min(node.url.startLine + context_lines, #content)
        for i = context_start_line, context_end_line do
          table.insert(snippet, content[i])
          if #content[i] > max_len then
            max_len = #content[i]
          end
        end
        break
      end
    end
  elseif config.database.sourceArchiveZip then
    local zipfile = config.database.sourceArchiveZip
    local path = string.gsub(node.filename, "^/", "")
    local content = vim.fn.systemlist(string.format("unzip -p -- %s %s", zipfile, path))
    context_start_line = math.max(node.url.startLine - context_lines, 0)
    local context_end_line = math.min(node.url.startLine + context_lines, #content)
    for i = context_start_line, context_end_line do
      table.insert(snippet, content[i])
      if #content[i] > max_len then
        max_len = #content[i]
      end
    end
  end

  -- create popup window
  local popup = Popup {
    enter = false,
    focusable = false,
    relative = "editor",
    border = {
      style = "rounded",
    },
    position = "50%",
    size = {
      width = max_len + 10,
      height = #snippet + 2,
    },
    buf_options = {
      modifiable = true,
      readonly = false,
      filetype = "markdown",
    },
    win_options = {
      winblend = 10,
      winhighlight = "Normal:NormalAlt,FloatBorder:FloatBorder",
    },
  }

  -- when cursor is moved, close the popup
  local current_bufnr = vim.api.nvim_get_current_buf()
  autocmd.buf.define(current_bufnr, event.CursorMoved, function()
    popup:unmount()
  end, { once = true })

  -- mount/open the component
  popup:mount()

  -- set content
  local _, _, ext = string.find(node.filename, "%.(%w+)$")
  local content = { "```" .. ext }
  vim.list_extend(content, snippet)
  vim.list_extend(content, { "```" })
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, 1, false, content)

  -- highlight node
  vim.api.nvim_buf_clear_namespace(popup.bufnr, range_ns, 0, -1)
  local startLine = node.url.startLine - context_start_line
  local startColumn = node.url.startColumn
  local endColumn = node.url.endColumn
  vim.api.nvim_buf_add_highlight(popup.bufnr, range_ns, "CodeqlRange", startLine + 1, startColumn - 1, endColumn - 1)
end

function M.open_panel()
  -- check if audit pane is already opened
  if vim.fn.bufwinnr(panel_buffer_name) ~= -1 then
    return
  end

  -- prepare split arguments
  local pos = ""
  if panel_pos == "right" then
    pos = "botright"
  elseif panel_pos == "left" then
    pos = "topleft"
  else
    util.err_message "Incorrect panel_pos value"
    return
  end

  -- get current win id
  local current_window = vim.fn.win_getid()

  -- go to main window
  go_to_main_window()

  -- split
  vim.fn.execute("silent keepalt " .. pos .. " vertical " .. panel_width .. "split " .. panel_buffer_name)

  -- go to original window
  vim.fn.win_gotoid(current_window)

  -- buffer options
  local bufnr = vim.fn.bufnr(panel_buffer_name)

  vim.api.nvim_buf_set_option(bufnr, "filetype", "codeql_panel")
  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(bufnr, "buflisted", false)

  -- window options
  local win = get_panel_window(panel_buffer_name)
  vim.api.nvim_win_set_option(win, "wrap", false)
  vim.api.nvim_win_set_option(win, "number", false)
  vim.api.nvim_win_set_option(win, "relativenumber", false)
  vim.api.nvim_win_set_option(win, "foldenable", false)
  vim.api.nvim_win_set_option(win, "winfixwidth", true)
  vim.api.nvim_win_set_option(win, "concealcursor", "nvi")
  vim.api.nvim_win_set_option(win, "conceallevel", 3)
  vim.api.nvim_win_set_option(win, "signcolumn", "yes")
end

function M.close_panel()
  local win = get_panel_window(panel_buffer_name)
  vim.api.nvim_win_close(win, true)
end

function M.render(issues, opts)
  opts = opts or {}
  issues = issues or {}
  M.open_panel()

  M.line_map = {}
  M.scan_results = {
    issues = issues or {},
    kind = opts.kind or "raw",
    columns = opts.columns or {},
    mode = opts.mode or "table",
  }

  local rule_groups = {}
  for _, issue in ipairs(issues) do
    if rule_groups[issue.rule_id] then
      table.insert(rule_groups[issue.rule_id], issue)
    else
      rule_groups[issue.rule_id] = { issue }
    end
  end

  local rules = {}
  local folded = #vim.tbl_keys(rule_groups) > 1 and true or false
  for group, rule_issues in pairs(rule_groups) do
    local rule = {
      mode = M.scan_results.mode,
      columns = M.scan_results.columns,
      issues = rule_issues,
      is_folded = folded,
      label = group,
    }
    table.insert(rules, rule)
  end
  M.scan_results.rules = rules

  render_content(M.scan_results)
end

return M
