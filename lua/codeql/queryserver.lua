local util = require "codeql.util"
local loader = require "codeql.loader"
local config = require "codeql.config"
local rpc = require "vim.lsp.rpc"
local protocol = require "vim.lsp.protocol"

local client_index = 0
local evaluate_id = 0
local progress_id = 0

local function next_client_id()
  client_index = client_index + 1
  return client_index
end

local function next_progress_id()
  progress_id = progress_id + 1
  return progress_id
end

local function next_evaluate_id()
  evaluate_id = evaluate_id + 1
  return evaluate_id
end

local M = {}

M.client = nil

function M.start_client(config)
  local cmd, cmd_args = util.cmd_parts(config.cmd)

  local client_id = next_client_id()

  local callbacks = config.callbacks or {}
  local name = config.name or tostring(client_id)
  local log_prefix = string.format("QueryServer[%s]", name)
  local handlers = {}

  local function resolve_callback(method)
    return callbacks[method] -- or default_callbacks[method]
  end

  function handlers.notification(method, params)
    local callback = resolve_callback(method)
    if callback then
      -- Method name is provided here for convenience.
      callback(method, params, client_id)
    end
  end

  function handlers.server_request(method, params)
    local callback = resolve_callback(method)
    if callback then
      return callback(method, params, client_id)
    end
    return nil, rpc.rpc_response_error(protocol.ErrorCodes.MethodNotFound)
  end

  function handlers.on_error(code, err)
    util.err_message(log_prefix, ": Error ", rpc.client_errors[code], ": ", vim.inspect(err))
    if config.on_error then
      local status, usererr = pcall(config.on_error, code, err)
      if not status then
        util.err_message(log_prefix, " user on_error failed: ", tostring(usererr))
      end
    end
  end

  function handlers.on_exit(code, signal)
    if config.on_exit then
      pcall(config.on_exit, code, signal)
    end
  end

  -- Start the RPC client.
  local client = rpc.start(cmd, cmd_args, handlers, {
    cwd = config.cmd_cwd,
    env = config.cmd_env,
  })
  client.id = client_id
  return client
end

function M.start_server()
  if M.client then
    return M.client
  end

  util.message "Starting CodeQL Query Server"
  -- TODO: make sure we are on 2.4.1 or greater
  local cmd = { "codeql", "execute", "query-server", "--require-db-registration", "-v", "--log-to-stderr" }
  local conf = config.get_config()
  vim.list_extend(cmd, conf.ram_opts)

  local last_message = ""

  local client_config = {
    cmd = cmd,
    offset_encoding = { "utf-8", "utf-16" },
    callbacks = {

      -- progress update
      ["ql/progressUpdated"] = function(_, params, _)
        local message = params.message
        if message ~= last_message and nil == string.match(message, "^Stage%s%d.*%d%s%-%s*$") then
          util.message(message)
        end
        last_message = message
      end,

      -- query completed
      ["evaluation/queryCompleted"] = function(_, result, _)
        util.message(string.format("Evaluation time: %s", result.evaluationTime))
        print(vim.inspect(result))
        if result.resultType == 0 then
          return {}
        elseif result.resultType == 1 then
          util.err_message(result.message or "ERROR: Other")
          return nil
        elseif result.resultType == 2 then
          util.err_message(result.message or "ERROR: OOM")
          return nil
        elseif result.resultType == 3 then
          util.err_message(result.message or "ERROR: Timeout")
          return nil
        elseif result.resultType == 4 then
          util.err_message(result.message or "ERROR: Query was cancelled")
          return nil
        end
      end,
    },
  }
  return M.start_client(client_config)
end

function M.run_query(opts)
  local dbDir = config.database.datasetFolder
  if not dbDir then
    --util.err_message "Cannot find dataset folder. Did you :SetDatabase?"
    return
  end

  if not M.client then
    M.client = M.start_server()
  end

  local bufnr = opts.bufnr
  local queryPath = opts.query
  local qloPath = string.format(vim.fn.tempname(), ".qlo")
  local bqrsPath = string.format(vim.fn.tempname(), ".bqrs")
  local libraryPath = opts.libraryPath
  local dbschemePath = opts.dbschemePath
  local dbPath = opts.dbPath
  if not vim.endswith(dbPath, "/") then
    dbPath = string.format("%s/", dbPath)
  end

  -- https://github.com/github/vscode-codeql/blob/master/extensions/ql-vscode/src/messages.ts
  -- https://github.com/github/vscode-codeql/blob/eec72e0cbd65fd0d5fea19c7f63104df2ebc8b07/extensions/ql-vscode/src/run-queries.ts#L171-L180
  local compileQuery_params = {
    body = {
      compilationOptions = {
        computeNoLocationUrls = true,
        failOnWarnings = false,
        fastCompilation = false,
        includeDilInQlo = true,
        localChecking = false,
        noComputeGetUrl = false,
        noComputeToString = false,
        computeDefaultStrings = true,
      },
      extraOptions = {
        timeoutSecs = 0,
      },
      queryToCheck = {
        libraryPath = libraryPath,
        dbschemePath = dbschemePath,
        queryPath = queryPath,
      },
      resultPath = qloPath,
      target = opts.quick_eval and {
        quickEval = {
          quickEvalPos = {
            fileName = queryPath,
            line = opts.startLine,
            column = opts.startColumn,
            endLine = opts.endLine,
            endColumn = opts.endColumn,
          },
        },
      } or {
        query = { xx = "" },
      },
    },
    progressId = next_progress_id(),
  }

  local runQueries_callback = function(err, _)
    if err then
      util.err_message "ERROR: runQuery failed"
    end
    if util.is_file(bqrsPath) then
      loader.process_results {
        bqrs_path = bqrsPath,
        bufnr = bufnr,
        db_path = dbPath,
        query_path = queryPath,
        query_kind = opts.metadata["kind"],
        query_id = opts.metadata["id"],
        save_bqrs = true,
      }
    else
      util.err_message "Query run failed. Database may be locked by a different Query Server"
    end
  end

  local compileQuery_callback = function(_, result)
    local failed = false
    if not result then
      return
    end
    for _, msg in ipairs(result.messages) do
      if msg.severity == 0 then
        util.err_message(msg.message)
        failed = true
      end
    end
    if failed then
      return
    else
      -- prepare `runQueries` params
      -- https://github.com/github/vscode-codeql/blob/81e60286f299660e0326d6036e0e0a0969ebbf51/extensions/ql-vscode/src/pure/messages.ts#L722
      -- https://github.com/github/vscode-codeql/blob/eec72e0cbd65fd0d5fea19c7f63104df2ebc8b07/extensions/ql-vscode/src/run-queries.ts#L123
      local runQueries_params = {
        body = {
          db = {
            dbDir = dbDir,
            workingSet = "default",
          },
          evaluateId = next_evaluate_id(),
          queries = {
            {
              resultsPath = bqrsPath,
              qlo = string.format("file://%s", qloPath),
              allowUnknownTemplates = true,
              templateValues = opts.templateValues or nil,
              id = 0,
              timeoutSecs = 0,
            },
          },
          stopOnError = false,
          useSequenceHint = false,
        },
        progressId = next_progress_id(),
      }

      -- run query
      util.message(string.format("Running query [%s]", M.client.pid))
      M.client.request("evaluation/runQueries", runQueries_params, runQueries_callback)
    end
  end

  -- compile query
  util.message(string.format("Compiling query %s", queryPath))

  M.client.request("compilation/compileQuery", compileQuery_params, compileQuery_callback)
end

function M.register_database(database)
  config.database = database
  if not M.client then
    M.client = M.start_server()
  end
  util.message(string.format("Registering database %s", config.database.datasetFolder))
  local params = {
    body = {
      databases = {
        {
          dbDir = config.database.datasetFolder,
          workingSet = "default",
        },
      },
      progressId = next_progress_id(),
    },
  }
  M.client.request("evaluation/registerDatabases", params, function(err, result)
    if err then
      util.err_message(string.format("Error registering database %s", vim.inspect(err)))
    else
      util.message(string.format("Successfully registered %s", result.registeredDatabases[1].dbDir))
    end
  end)
end

function M.unregister_database()
  if not config.database then
    util.err_message "No database registered"
    return
  end
  if not M.client then
    M.client = M.start_server()
  end
  util.message(string.format("Unregistering database %s", config.database.datasetFolder))
  local params = {
    body = {
      databases = {
        {
          dbDir = config.database.datasetFolder,
          workingSet = "default",
        },
      },
      progressId = next_progress_id(),
    },
  }
  M.client.request("evaluation/deregisterDatabases", params, function(err, result)
    if err then
      util.err_message(string.format("Error registering database %s", vim.inspect(err)))
    elseif #result.registeredDatabases == 0 then
      util.message(string.format("Successfully deregistered %s", config.database.datasetFolder))
      config.database = nil
    end
  end)
end

function M.stop_server()
  if M.client then
    local handle = M.client.handle
    handle:kill()
    M.client = nil
  end
end

return M
