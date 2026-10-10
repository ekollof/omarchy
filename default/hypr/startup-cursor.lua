-- Hyprland polls cursor.invisible, so its first frames need a blank cursor too.
--
-- A `hyprctl reload` while the restore is pending (e.g. from
-- omarchy-hyprland-monitor-watch while a slow display is still waking up)
-- wipes this module's Lua state without touching the compositor's config or
-- environment. The captured cursor therefore also lives in the runtime dir,
-- so a fresh state that still sees the blank theme picks the restore back up
-- instead of stranding the pointer invisible.
local function omarchy_startup_cursor_state_path()
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  if not runtime or runtime == "" then return nil end
  return runtime .. "/omarchy-startup-cursor.lua"
end

local function omarchy_startup_cursor_save(cursor)
  local path = omarchy_startup_cursor_state_path()
  if not path then return end
  local file = io.open(path, "w")
  if not file then return end
  file:write("return {\n")
  file:write("invisible = " .. tostring(cursor.config.invisible) .. ",\n")
  file:write("enable_hyprcursor = " .. tostring(cursor.config.enable_hyprcursor) .. ",\n")
  file:write("sync_gsettings_theme = " .. tostring(cursor.config.sync_gsettings_theme) .. ",\n")
  file:write("hyprcursor = " .. (cursor.hyprcursor and string.format("%q", cursor.hyprcursor) or "nil") .. ",\n")
  file:write("size = " .. tostring(cursor.size) .. ",\n")
  file:write("path = " .. string.format("%q", cursor.path) .. ",\n")
  file:write("xcursor = " .. string.format("%q", cursor.xcursor) .. ",\n")
  file:write("}\n")
  file:close()
end

local function omarchy_startup_cursor_drop()
  local path = omarchy_startup_cursor_state_path()
  if path then os.remove(path) end
end

local function omarchy_startup_cursor_load()
  local path = omarchy_startup_cursor_state_path()
  if not path then return nil end
  local chunk = loadfile(path)
  if not chunk then return nil end
  local ok, saved = pcall(chunk)
  if not ok or type(saved) ~= "table" then return nil end
  if type(saved.xcursor) ~= "string" or saved.xcursor == "" or saved.xcursor == "omarchy-startup" then return nil end
  if type(saved.path) ~= "string" or saved.path == "" then return nil end
  return {
    config = {
      invisible = saved.invisible == true,
      enable_hyprcursor = saved.enable_hyprcursor == true,
      sync_gsettings_theme = saved.sync_gsettings_theme ~= false,
    },
    hyprcursor = (type(saved.hyprcursor) == "string" and saved.hyprcursor ~= "") and saved.hyprcursor or nil,
    size = (type(saved.size) == "number" and saved.size > 0) and saved.size or 24,
    path = saved.path,
    xcursor = saved.xcursor,
  }
end

function omarchy_startup_cursor_restore(loaded)
  if not omarchy_startup_cursor_pending then return end
  local cursor = omarchy_startup_cursor
  if loaded then
    omarchy_startup_cursor_pending = false
    hl.config({ cursor = cursor.config })
    local theme = (cursor.config.enable_hyprcursor and cursor.hyprcursor and cursor.hyprcursor ~= "" and cursor.hyprcursor) or cursor.xcursor
    hl.exec_cmd("hyprctl setcursor " .. o.shell_quote(theme) .. " " .. cursor.size)
    omarchy_startup_cursor_drop()
  elseif not cursor.restoring then
    -- Reload the normal Xcursor fallback before enabling Hyprcursor or GSettings.
    cursor.restoring = true
    hl.exec_cmd("hyprctl setcursor " .. o.shell_quote(cursor.xcursor) .. " " .. cursor.size
      .. " && hyprctl eval 'omarchy_startup_cursor_restore(true)'")
  end
end

hl.on("config.reloaded", function()
  if omarchy_startup_cursor_pending == nil then
    -- Config updates in an existing compositor must not hide its pointer.
    omarchy_startup_cursor_pending = #hl.get_monitors() == 0
    if omarchy_startup_cursor_pending then
      local hyprcursor = hl.get_config("cursor.enable_hyprcursor")
      omarchy_startup_cursor = {
        config = {
          invisible = hl.get_config("cursor.invisible"),
          enable_hyprcursor = hyprcursor,
          sync_gsettings_theme = hl.get_config("cursor.sync_gsettings_theme"),
        },
        hyprcursor = os.getenv("HYPRCURSOR_THEME"),
        size = tonumber((hyprcursor and os.getenv("HYPRCURSOR_SIZE")) or os.getenv("XCURSOR_SIZE")) or 24,
        path = os.getenv("XCURSOR_PATH") or "~/.local/share/icons:~/.icons:/usr/share/icons:/usr/share/pixmaps",
        xcursor = os.getenv("XCURSOR_THEME") or "default",
      }
      if omarchy_startup_cursor.size <= 0 then omarchy_startup_cursor.size = 24 end
      hl.env("XCURSOR_PATH", os.getenv("OMARCHY_PATH") .. "/default/hypr/cursors:" .. omarchy_startup_cursor.path)
      hl.env("XCURSOR_THEME", "omarchy-startup")
      omarchy_startup_cursor_save(omarchy_startup_cursor)
    elseif os.getenv("XCURSOR_THEME") == "omarchy-startup" then
      -- A reload wiped a pending restore: the compositor still shows the
      -- blank theme but this state is fresh. Pick the restore back up from
      -- the saved capture instead of stranding the pointer.
      local saved = omarchy_startup_cursor_load()
      if saved then
        omarchy_startup_cursor = saved
        omarchy_startup_cursor_pending = true
      end
    else
      -- Healthy session: a leftover capture (e.g. from a crash) must never
      -- hide the pointer of a later reload.
      omarchy_startup_cursor_drop()
    end
  end
  if omarchy_startup_cursor_pending then
    -- Keep the temporary cursor private to the compositor, including GSettings.
    hl.config({ cursor = { invisible = true, enable_hyprcursor = false, sync_gsettings_theme = false } })
    hl.timer(function() omarchy_startup_cursor_restore() end, { timeout = 15000, type = "oneshot" })
  end
end)
