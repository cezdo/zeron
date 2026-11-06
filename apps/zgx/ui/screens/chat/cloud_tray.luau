-- A chat's Cloud machine, on its composer: its state on the composer's notice
-- line, and the one alert (screens/chat/cloud_machine) in a tray behind the
-- pill (ds/composer_dock's `alert`), its sizes opening under it.
--
-- `bind` is the glue a composer takes: tracked reads and the actions, nothing
-- drawn. `Body` is the tray's drawing: the only part that knows how any of it
-- looks.
--
--   local machine = CloudTray.bind { chat = fn, device = fn, running = fn }
--   Composer { alert = machine.tray, alert_body = CloudTray.Body(machine),
--     on_dismiss_alert = machine.dismiss, … }
--   LinkNotice.of { cloud = machine.cloud_link(), … }

local ds = require("@ds")
local cloud = require("@account/cloud")
local logic = require("@app/screens/chat/cloud_machine")
local route = require("@app/screens/shell/route")

local M = {}

-- What's been put away, by chat (logic.dismiss): kept across launches.
local PUT_AWAY = ui.persist("cloud_alerts_put_away", {} :: { [string]: { [string]: string } })
-- The hour, for what's said of a date: enough to move "in 3 days" on its own,
-- and nothing draws faster for it.
local HOUR = ui.state("cloud_alerts_hour", 0)

export type Bind = {
	chat: () -> string?,
	device: () -> string?,
	running: (() -> boolean)?,
}

function M.bind(c: Bind): any
	local b: any = {}
	-- Is this chat's machine one of Cloud's? Then its sessions are followed.
	cloud.follow(function(): boolean
		return c.chat() ~= nil and cloud.on_device(c.device())
	end)
	ui.effect(function()
		if not cloud.on_device(c.device()) then
			return
		end
		HOUR:set(os.time() // 3600)
		ui.every(60000, function()
			local h = os.time() // 3600
			if HOUR:peek() ~= h then
				HOUR:set(h)
			end
		end)
	end)
	function b.session(): any
		return cloud.session_for(c.chat(), c.device())
	end
	-- Its levels fell or cleared: what was put away moves with them.
	ui.effect(function()
		local s = b.session()
		-- (Not before the hour's known: every date would read as far off.)
		if s and HOUR:get() > 0 then
			local settled = logic.settle(PUT_AWAY:peek(), s, HOUR:get() * 3600)
			if settled ~= PUT_AWAY:peek() then
				PUT_AWAY:set(settled)
			end
		end
	end)
	-- A session's chat: a side chat acts on its parent's machine.
	local function owner(): string?
		local s = b.session()
		return s and s.chat
	end
	function b.wake_state(): any
		return cloud.wake_state(owner())
	end
	b.alert = ui.computed(function(): logic.Alert?
		local s = b.session()
		if not s then
			return nil
		end
		local put_away = PUT_AWAY:get()
		return logic.alert(s, {
			now = HOUR:get() * 3600,
			failure = b.wake_state().failure,
			dismissed = function(kind: string, level: string): boolean
				return logic.dismissed(put_away, s.chat, kind, level)
			end,
		})
	end)
	b.picker = ui.computed(function(): logic.Picker?
		local s, a = b.session(), b.alert:get()
		if not s or not a or not a.picks then
			return nil
		end
		return logic.picker(s, cloud.machines(), a, { running = c.running ~= nil and c.running() })
	end)
	-- The composer's tray: the alert as data, keyed so a new one is news.
	b.tray = ui.computed(function(): any
		local a = b.alert:get()
		if not a then
			return nil
		end
		return {
			key = `{owner() or ""}:{a.kind}`,
			tone = a.tone,
			title = a.title,
			summary = a.summary,
			dismissable = a.dismissable == true,
			opens = a.opens == true,
		}
	end)
	-- For LinkNotice.of: whether this chat is one of Cloud's, and its line.
	function b.cloud_link(): any
		local s = b.session()
		if not s then
			return nil
		end
		return { line = logic.line(s, cloud.machines()) }
	end
	function b.dismiss()
		local s, a = b.session(), b.alert:peek()
		if not s or not a then
			return
		end
		if a.kind == "wake_failed" then
			cloud.clear_failure(s.chat)
		elseif a.level then
			PUT_AWAY:set(logic.dismiss(PUT_AWAY:peek(), s.chat, a.kind, a.level))
		end
	end
	-- The actions: a size picked, the line's Wake, and the alert's way on.
	function b.pick(machine: string)
		local s = b.session()
		if not s then
			return
		end
		if s.state == "ready" then
			cloud.resize(s.chat, machine)
		else
			cloud.wake(s.chat, machine)
		end
	end
	function b.wake()
		local chat = owner()
		if chat then
			cloud.wake(chat)
		end
	end
	function b.act(action: string?)
		local s = b.session()
		if not s then
			return
		end
		if action == "fresh" then
			cloud.fresh(s.chat, cloud.machine())
		elseif action == "retry" or action == "wake" then
			cloud.wake(s.chat)
		elseif action == "new_chat" then
			route.new_chat(s.space)
		end
	end
	return b
end

-- ── The drawing ────────────────────────────────────────────────────────────

local Size = ui.component(function(props: { row: State<logic.Row>, on_pick: (id: string) -> () }): Node
	local row = props.row
	local over = ui.use_state(false)
	local function off(): boolean
		return row:get().disabled
	end
	return ui.row {
		role = "button",
		label = function(): string
			local r = row:get()
			return `{r.name}, {r.specs}, {r.rate}{if r.reason then `, {r.reason}` else ""}`
		end,
		disabled = off,
		focusable = function(): boolean
			return not off()
		end,
		w_full = true,
		min_h = "$zeron.composer.tray.row",
		px = "$space.2",
		py = "$space.1",
		gap = "$space.3",
		items = "center",
		rounded = "$zeron.composer.tray.row_radius",
		bg = function(): string
			return if over:get() and not off() then "$hover" else "#00000000"
		end,
		cursor = function(): any
			return if off() then nil else "pointer"
		end,
		opacity = function(): any
			return if off() then "$zeron.disabled" else 1
		end,
		on_hover = function(inside: boolean)
			over:set(inside)
		end,
		on_click = function()
			if not off() then
				props.on_pick(row:peek().id)
			end
		end,
		ui.column {
			grow = 1,
			min_w = 0,
			ui.text {
				function(): string
					return row:get().name
				end,
				text_size = "$font.size.md",
				line_height = "$font.line.md",
				weight = "$font.weight.medium",
				color = "$text.primary",
			},
			ui.text {
				function(): string
					return row:get().specs
				end,
				text_size = "$font.size.sm",
				line_height = "$font.line.sm",
				color = "$text.tertiary",
			},
		},
		ui.show(function(): boolean
			return row:get().reason ~= nil
		end, ui.text {
			function(): string
				return row:get().reason or ""
			end,
			shrink = 0,
			text_size = "$font.size.sm",
			line_height = "$font.line.sm",
			color = "$text.secondary",
		}),
		ui.text {
			function(): string
				return row:get().rate
			end,
			shrink = 0,
			tabular = true,
			text_size = "$font.size.sm",
			line_height = "$font.line.sm",
			color = "$text.secondary",
		},
	}
end)

local function words(text: () -> string): Node
	return ui.text {
		text,
		wrap = true,
		text_size = "$font.size.md",
		line_height = "$font.line.md",
		color = "$text.secondary",
	}
end

-- The tray's opened body: its words, the sizes when it lists them, and its way
-- on.
M.Body = ui.component(function(b: any): Node
	local function picker(): logic.Picker?
		return b.picker:get()
	end
	local rows = ui.computed(function(): { logic.Row }
		local p = picker()
		return if p then p.rows else {}
	end)
	-- The way on: the alert's own, or what's offered when no size will do.
	local function way(): (string?, string?)
		local a, p = b.alert:get(), picker()
		if p and p.action then
			return p.action, p.action_label
		end
		if a and a.action then
			return a.action, a.action_label
		end
		return nil, nil
	end
	return ui.column {
		w_full = true,
		px = "$space.2",
		pt = "$space.1",
		pb = "$space.2",
		gap = "$space.2",
		id = "cloud-tray-body",
		words(function(): string
			local a, p = b.alert:get(), picker()
			return (p and p.body) or (a and a.body) or ""
		end),
		ui.show(function(): boolean
			return #rows:get() > 0
		end, ui.column {
			w_full = true,
			mx = ui.raw(-4, "a row's wash runs a little past the words over it"),
			gap = "$zeron.space.hair",
			ui.each(rows, function(_r: logic.Row, _i: number, row: State<logic.Row>): Node
				return Size { row = row, on_pick = b.pick }
			end, {
				key = function(r: logic.Row): string
					return r.id
				end,
				w_full = true,
			}),
		}),
		ui.show(function(): boolean
			local p = picker()
			return p ~= nil and p.note ~= nil
		end, ui.text {
			function(): string
				local p = picker()
				return (p and p.note) or ""
			end,
			wrap = true,
			text_size = "$font.size.sm",
			line_height = "$font.line.sm",
			color = "$text.tertiary",
		}),
		-- A pick that was just refused, while the sizes are still up to pick.
		ui.show(function(): boolean
			return b.wake_state().failure ~= nil and picker() ~= nil
		end, ui.text {
			function(): string
				local f = b.wake_state().failure
				return if f then logic.failure_words(f) else ""
			end,
			wrap = true,
			text_size = "$font.size.sm",
			line_height = "$font.line.sm",
			color = "$zeron.tone.danger.ink",
		}),
		ui.show(function(): boolean
			local action = way()
			return action ~= nil
		end, ui.row {
			gap = "$space.2",
			ds.Button {
				function(): string
					local _, label = way()
					return label or ""
				end,
				size = "sm",
				tone = "secondary",
				busy = function(): boolean
					return b.wake_state().busy == true
				end,
				on_click = function()
					local action = way()
					b.act(action)
				end,
			},
		}),
	}
end)

return M
