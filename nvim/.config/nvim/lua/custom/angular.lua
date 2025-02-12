local M = {}

function M.generate_component(skipTests)
  local inputs = require("neo-tree.ui.inputs")
  inputs.input("Component's name", "", function(input)
    local state = require("neo-tree.sources.manager").get_state("filesystem")

    local node = state.tree:get_node()
    if node and node.path then
      if node.type == "directory" then
        vim.cmd(("cd " .. node.path))
        local cmd = { "ng", "g", "c", "--defaults" }
        if skipTests then
          table.insert(cmd, "--skip-tests")
        end
        table.insert(cmd, input)
        vim.fn.system(cmd)
      end
    end
  end)
end

function M.generate_service(skipTests)
  local inputs = require("neo-tree.ui.inputs")
  inputs.input("Services's name", "", function(input)
    local state = require("neo-tree.sources.manager").get_state("filesystem")

    local node = state.tree:get_node()
    if node and node.path then
      if node.type == "directory" then
        vim.cmd(("cd " .. node.path))
        local cmd = { "ng", "g", "s", "--defaults" }
        if skipTests then
          table.insert(cmd, "--skip-tests")
        end
        table.insert(cmd, input)
        vim.fn.system(cmd)
      end
    end
  end)
end

function M.rename_component()
  local state = require("neo-tree.sources.manager").get_state("filesystem")
  local fs = require("neo-tree.sources.filesystem")
  local node = state.tree:get_node()

  if node and node.path and node.type == "directory" then
    local node_expander = require("neo-tree.sources.common.node_expander")
    node_expander.expand_directory_recursively(state, node, fs.prefetcher)
    for _, child in ipairs(state.tree:get_nodes(node:get_id())) do
      local index = string.find(child.name, "%.component%.ts$")
      if index == nil then
        goto continue
      end
      local dashed_old_component = string.sub(child.name, 1, index - 1)
      local inputs = require("neo-tree.ui.inputs")
      local uv = vim.uv
      local utils = require("neo-tree.utils")
      local clients = vim.lsp.get_clients()

      local pascal_old_component = (dashed_old_component:gsub("-(%w)", function(c)
        return c:upper()
      end)):gsub("^(.)", function(c)
        return c:upper()
      end)

      -- TODO: Rename the component class before renaming the file path.
      -- Otherwise it breaks in comopnents that refer it

      inputs.input("Rename component", pascal_old_component, function(input)
        input = input:gsub("^%l", string.upper)
        local dashed_component_name = input:gsub("(%l)(%u)", "%1-%2"):lower()

        local parent_folder_path, _ = utils.split_path(node.path)

        vim.fn.system("cd " .. parent_folder_path .. "&& mkdir " .. dashed_component_name)

        for _, sub_node in ipairs(state.tree:get_nodes(node:get_id())) do
          local hit = string.find(sub_node.name, (dashed_old_component:gsub("-", "%%-") .. "%.component%."))
          if hit ~= nil then
            local parent_folder, _ = assert(utils.split_path(sub_node.path))
            local parent_path, _ = utils.split_path(parent_folder)
            local _, extension = sub_node.name:match("^(.-)(%..+)$")
            local newUri = parent_path
              .. utils.path_separator
              .. dashed_component_name
              .. utils.path_separator
              .. dashed_component_name
              .. extension

            local oldUri = sub_node.path

            uv.fs_rename(oldUri, newUri, function(err)
              -- INFO: Notify LSP
              -- clients is an array of Client[]. This means that ipairs will return the index as the key and client as the value
              for _, client in ipairs(clients) do
                client.notify("workspace/didRenameFiles", {
                  files = {
                    {
                      oldUri = oldUri,
                      newUri = newUri,
                    },
                  },
                })
              end

              local ts_hit = string.find(newUri, "%.component%.ts$")
              if ts_hit ~= nil then
                vim.schedule(function()
                  utils.open_file(state, newUri, "e")

                  local bufnr = utils.find_buffer_by_name(newUri)

                  local lnum, col = unpack(vim.fn.searchpos([[@Component\(.\|\n\)\+export class \zs\(\w\+\)\ze]], "n"))

                  vim.api.nvim_set_current_buf(bufnr)

                  -- TODO: Grab the selector value before the modification for a global search and replace using ripgrep + sed

                  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                  local content = table.concat(lines)
                  local selector = content:match("selector.-['|\"](.-)['|\"]")

                  local selector_prefix =
                    content:match("selector.-['|\"](.-)%-" .. dashed_old_component:gsub("-", "%%-") .. "['|\"]")

                  local stylesheet = content:match("styleUrl.-['|\"](.-)['|\"]")
                  local stylesheet_extension = stylesheet:match(".+(%..-)$")

                  local root_dir

                  -- Loop through clients to find angularls
                  for _, client in ipairs(clients) do
                    if client.name == "angularls" then
                      root_dir = client.config.root_dir
                    end
                  end

                  vim.bo.ma = true

                  vim.api.nvim_command(
                    [[:%s/selector.\+\zs]] .. dashed_old_component .. [[\ze/]] .. dashed_component_name
                  )
                  vim.api.nvim_command(
                    [[:%s/templateUrl[^']\+'\zs.\+\ze'/.\/]] .. dashed_component_name .. ".component.html"
                  )
                  vim.api.nvim_command(
                    [[:%s/styleUrl[^']\+'\zs.\+\ze'/.\/]]
                      .. dashed_component_name
                      .. ".component"
                      .. stylesheet_extension
                  )

                  vim.fn.system(
                    "cd "
                      .. root_dir
                      .. "&& rg '"
                      .. selector
                      .. "' -l | xargs perl -i -0777 -pe 's/<(\\/?)"
                      .. selector
                      .. "([^>]*)>/<\\1"
                      .. selector_prefix
                      .. "-"
                      .. dashed_component_name
                      .. "\\2>/mg'"
                  )

                  vim.api.nvim_command("w!")

                  -- -- INFO: Notify LSP
                  local file_uri = vim.uri_from_fname(newUri)
                  for _, client in ipairs(clients) do
                    if client.name == "vtsls" then
                      client.request("textDocument/rename", {
                        newName = input .. "Component",
                        textDocument = {
                          uri = file_uri,
                        },
                        position = {
                          line = lnum - 1,
                          character = col - 1,
                        },
                      }, function(err, result, context, config)
                        if err ~= nil then
                          print(err)
                        elseif result ~= nil then
                          for uri, text_edits in pairs(result.changes) do
                            local fname = vim.uri_to_fname(uri)
                            local buf = vim.fn.bufadd(fname)

                            vim.fn.bufload(buf)

                            for _, edit in pairs(text_edits) do
                              vim.api.nvim_buf_set_text(
                                buf,
                                edit.range.start.line,
                                edit.range.start.character,
                                edit.range["end"].line,
                                edit.range["end"].character,
                                { edit.newText }
                              )
                            end
                          end
                        end
                      end)
                    end
                  end
                end)
              end
            end)
          end
        end
        vim.fn.system("cd " .. parent_folder_path .. "&& rmdir " .. dashed_old_component)
      end)
      ::continue::
    end
  end
end

function dump(o)
  if type(o) == "table" then
    local s = "{ "
    for k, v in pairs(o) do
      if type(k) ~= "number" then
        k = '"' .. k .. '"'
      end
      s = s .. "[" .. k .. "] = " .. dump(v) .. ","
    end
    return s .. "} "
  else
    return tostring(o)
  end
end

local wk = require("which-key")

wk.add({
  "<leader>Agc",
  function()
    M.generate_component(false)
  end,
  desc = "Generate Standalone Component",
})

wk.add({
  "<leader>AgC",
  function()
    M.generate_component(true)
  end,
  desc = "Generate Standalone Component (Skip Tests)",
})

wk.add({
  "<leader>Ags",
  function()
    M.generate_service(false)
  end,
  desc = "Generate Service",
})

wk.add({
  "<leader>AgS",
  function()
    M.generate_service(true)
  end,
  desc = "Generate Service (Skip Tests)",
})

wk.add({
  "<leader>Acr",
  M.rename_component,
  desc = "Rename Component",
})

return M
