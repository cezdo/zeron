-- What's said of a chat's Cloud machine, and what can be done about it: pure
-- functions over a session and the sizes on offer, nothing drawn. Whatever
-- draws it (screens/chat/cloud_tray, Settings → Cloud) only reads these, so
-- the drawing can change with none of this moving.
--
--   line(session, machines)        the composer's one line: its state
--   alert(session, opts)           the one thing to raise over the composer
--   picker(session, machines, a, opts)  the sizes for that alert, each enabled
--                                  or not and why, and whether any will do
--   default_options(machines)      Settings → Cloud's default size choices
--   dismissed / dismiss / settle   dismissal: an alert put away stays away
--                                  until its level worsens
--
-- A test requires this module alone, in a VM with no `ui`: there, the English
-- it says (as screens/chat/link_notice).

local M = {}

local function say(key: string, english: string, args: { [string]: any }?): string
	if (ui :: any) == nil then
		return english
	end
	return ui.t(`chat.cloud_machine.{key}`, args):get()
end

export type Notice = { text: string, tone: string?, spinner: boolean?, action: string? }

-- ── Numbers ────────────────────────────────────────────────────────────────

-- "111": whole gigabytes. Rounded down for what a machine holds (never claim
-- room it hasn't got), up for what a chat needs.
function M.holds_gb(n: number): number
	return math.floor(n)
end
function M.needs_gb(n: number): number
	return math.ceil(n)
end

-- "1×", "0.5×", "5.56×": as many places as it has, at most two.
function M.rate(multiplier: number?): string
	local m = multiplier or 1
	local text = string.format("%.2f", m)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return `{text}×`
end

local function whole(n: number): string
	local text = string.format("%.1f", n)
	text = string.gsub(text, "%.0$", "")
	return text
end

-- "4 vCPU · 16 GB memory · 111 GB disk".
function M.specs(m: any): string
	return say("specs", `{whole(m.vcpu)} vCPU · {whole(m.memory_gb)} GB memory · {M.holds_gb(m.disk_gb)} GB disk`, {
		vcpu = whole(m.vcpu),
		memory = whole(m.memory_gb),
		disk = tostring(M.holds_gb(m.disk_gb)),
	})
end

function M.machine_name(m: any): string
	return m.name or m.id
end

local function find(machines: { any }?, id: string?): any
	if id then
		for _, m in machines or {} do
			if m.id == id then
				return m
			end
		end
	end
	return nil
end

-- ── The composer's line ────────────────────────────────────────────────────

-- A stage the edge names (the steps a machine's setup chips use): its words.
-- A stage in words of its own is the edge's sentence; anything else is left
-- out rather than showing an id.
local function stage_words(stage: string?): string?
	if not stage then
		return nil
	end
	if stage == "start" or stage == "wake" or stage == "clone" or stage == "branch" then
		if stage == "clone" then
			return say("stage_clone", "cloning the repository")
		elseif stage == "branch" then
			return say("stage_branch", "checking out the branch")
		end
		return say("stage_start", "starting up")
	end
	return if string.find(stage, " ", 1, true) then stage else nil
end

-- The line above the pill, for a chat whose machine is doing nothing worth
-- raising an alert for. Nil where the alert says it all (`alert`), or the
-- state says nothing. `action`: its button, waking it.
function M.line(s: any, machines: { any }?): Notice?
	local state = s.state
	if state == "data_expired" or state == "error" or (s.wake_blocked and s.wake_blocked.reason == "disk_too_small") then
		return nil
	end
	if state == "sleeping" then
		return { text = say("asleep", "Cloud machine asleep — it wakes when you send"), action = say("wake", "Wake") }
	elseif state == "provisioning" or state == "starting" then
		local stage = stage_words(s.stage)
		if stage then
			return { text = say("waking_stage", `Waking its Cloud machine — {stage}…`, { stage = stage }), spinner = true }
		end
		return {
			text = if state == "provisioning"
				then say("provisioning", "Starting a Cloud machine…")
				else say("waking", "Waking its Cloud machine…"),
			spinner = true,
		}
	elseif state == "stopping" then
		return { text = say("stopping", "Its Cloud machine is going to sleep…"), spinner = true }
	elseif state == "deleting" then
		return { text = say("deleting", "Deleting its Cloud machine…"), spinner = true }
	elseif state == "ready" then
		local m = find(machines, s.machine)
		if m then
			return { text = say("ready_on", `Cloud machine ready · {M.machine_name(m)}`, { name = M.machine_name(m) }) }
		end
		return { text = say("ready", "Cloud machine ready") }
	end
	return nil
end

-- ── The alert ──────────────────────────────────────────────────────────────

local DAY = 86400
-- How far off a sleeping machine's files going is worth a word, then more.
local EXPIRY_SOON, EXPIRY_VERY_SOON = 7 * DAY, DAY

-- A level's rank within its kind: higher is worse.
local RANK = { ok = 0, warn = 1, critical = 2, soon = 1, very_soon = 2 }

function M.rank(level: string?): number
	return RANK[level or "ok"] or 0
end

-- nil, "soon" or "very_soon".
function M.expiry_level(s: any, now: number): string?
	if s.state ~= "sleeping" or not s.expires then
		return nil
	end
	local left = s.expires - now
	if left <= EXPIRY_VERY_SOON then
		return "very_soon"
	end
	return if left <= EXPIRY_SOON then "soon" else nil
end

-- How many days are left, the nearest whole number, at least one.
local function days_left(s: any, now: number): number
	return math.max(1, math.floor((s.expires - now) / DAY + 0.5))
end

-- How full its disk is, 0 to 100, whole.
function M.percent_full(disk: any): number
	if not disk.capacity or disk.capacity <= 0 then
		return 0
	end
	return math.clamp(math.floor(disk.used / disk.capacity * 100), 0, 100)
end

export type Alert = {
	-- wake_blocked, wake_failed, failed, data_expired, expiring, disk.
	kind: string,
	-- What dismissal compares: a kind that can be put away has one.
	level: string?,
	tone: string,
	title: string,
	-- The folded line.
	summary: string,
	-- The opened words.
	body: string,
	-- The kinds that list the sizes.
	picks: boolean?,
	-- What it offers besides: "fresh", "retry" or "wake" (the picker may offer
	-- "new_chat").
	action: string?,
	action_label: string?,
	dismissable: boolean?,
	-- Comes in open: nothing to choose, its words and its one way on.
	opens: boolean?,
}

-- Why a wake failed, in words: a word the host has for it, or its sentence.
function M.failure_words(word: string): string
	if word == "disk_too_small" then
		return say("too_small", "That size can't hold this chat's files. Pick a bigger one.")
	elseif word == "offline" then
		return say("offline", "You're offline. Try again once you're back.")
	elseif word == "outdated" then
		return say("outdated", "This version of Zeron can't wake Cloud machines. Update it in About.")
	elseif string.find(word, " ", 1, true) then
		return word
	end
	return say("wake_failed_body", "The machine didn't wake. Try again in a moment.")
end

-- The one thing to raise for a session, or nil. One at a time, worst first, so
-- they never compete:
--
--   its files are gone > it can't wake > it failed > a wake just refused
--   > its disk is critical > its files going soon > its disk filling
--
-- Opts: `now` (Unix seconds), `failure` (the last wake's word), `dismissed`
-- (`level -> bool`, whether a kind at a level is put away).
function M.alert(s: any, opts: { now: number, failure: string?, dismissed: ((kind: string, level: string) -> boolean)? }): Alert?
	local function put_away(kind: string, level: string): boolean
		return opts.dismissed ~= nil and opts.dismissed(kind, level)
	end
	if s.state == "data_expired" then
		return {
			kind = "data_expired",
			tone = "warning",
			title = say("expired_title", "Machine's files are gone"),
			summary = say("expired_summary", "The conversation is kept"),
			body = if s.repo
				then say("expired_body_on", `This chat's machine slept too long and its files were deleted. The conversation is kept. A fresh machine starts over from {s.repo}, on the same branch; what was pushed comes back with it.`, { repo = s.repo })
				else say("expired_body", "This chat's machine slept too long and its files were deleted. The conversation is kept. A fresh machine starts over from its repository, on the same branch; what was pushed comes back with it."),
			action = "fresh",
			action_label = say("fresh", "Start a fresh machine"),
			opens = true,
		}
	end
	local blocked = s.wake_blocked
	if blocked and blocked.reason == "disk_too_small" then
		local needed = M.needs_gb(blocked.needed or 0)
		return {
			kind = "wake_blocked",
			tone = "warning",
			title = say("blocked_title", "Machine can't wake"),
			summary = say("blocked_summary", `It needs {needed} GB of disk`, { needed = needed }),
			body = say("blocked_body", `This chat's machine can't wake: it needs {needed} GB of disk. Pick a size that holds it, and it wakes there.`, { needed = needed }),
			picks = true,
		}
	end
	if s.state == "error" then
		local why = s.error or say("failed_unknown", "Something went wrong on its machine.")
		return {
			kind = "failed",
			tone = "danger",
			title = say("failed_title", "Machine failed"),
			summary = why,
			body = why,
			action = "retry",
			action_label = say("retry", "Try again"),
			opens = true,
		}
	end
	if opts.failure then
		local why = M.failure_words(opts.failure)
		return {
			kind = "wake_failed",
			tone = "danger",
			title = say("wake_failed_title", "Machine didn't wake"),
			summary = why,
			body = why,
			action = "retry",
			action_label = say("retry", "Try again"),
			dismissable = true,
			opens = true,
		}
	end
	local function disk_alert(): Alert?
		local d = s.disk
		if not d or (d.level ~= "warn" and d.level ~= "critical") or put_away("disk", d.level) then
			return nil
		end
		local percent = M.percent_full(d)
		local used, capacity = M.needs_gb(d.used), M.holds_gb(d.capacity)
		return {
			kind = "disk",
			level = d.level,
			tone = if d.level == "critical" then "danger" else "warning",
			title = say("disk_title", `Disk {percent}% full`, { percent = percent }),
			summary = say("disk_summary", `{used} of {capacity} GB on this chat's machine`, { used = used, capacity = capacity }),
			body = if d.level == "critical"
				then say("disk_body_critical", `This chat's machine has used {used} of its {capacity} GB and can fail once it's full. A bigger size gives it room.`, { used = used, capacity = capacity })
				else say("disk_body", `This chat's machine has used {used} of its {capacity} GB. A bigger size gives it room before it runs out.`, { used = used, capacity = capacity }),
			picks = true,
			dismissable = true,
		}
	end
	local disk = disk_alert()
	if disk and disk.level == "critical" then
		return disk
	end
	local expiry = M.expiry_level(s, opts.now)
	if expiry and not put_away("expiring", expiry) then
		local days = days_left(s, opts.now)
		local in_days = if days == 1 then "1 day" else `{days} days`
		return {
			kind = "expiring",
			level = expiry,
			tone = "neutral",
			title = say("expiring_title", "Machine asleep"),
			summary = say("expiring_summary", `Its files are deleted in {in_days}`, { days = days }),
			body = say("expiring_body", `This chat's machine has been asleep a while. Its files are deleted in {in_days} unless it wakes; the conversation is kept either way.`, { days = days }),
			action = "wake",
			action_label = say("wake_now", "Wake it now"),
			dismissable = true,
		}
	end
	return disk
end

-- ── The sizes ──────────────────────────────────────────────────────────────

export type Row = {
	id: string,
	name: string,
	specs: string,
	rate: string,
	current: boolean,
	disabled: boolean,
	-- Why it can't be picked ("holds 111 GB"), when it can't.
	reason: string?,
}
export type Picker = {
	rows: { Row },
	-- None of them will do: what can be done instead.
	none_fit: boolean,
	-- In the alert's words' place, when those would ask for a pick there's no
	-- way to make.
	body: string?,
	-- Said under them.
	note: string?,
	-- Offered when none fit.
	action: string?,
	action_label: string?,
}

-- Every size on offer, those that won't do disabled with a short reason. For
-- a machine that can't wake, what won't hold what it needs; for a disk filling,
-- also what's no bigger than it has now. `running`: a turn is on (a machine
-- that's up has to restart to change size), so nothing's picked until it ends.
function M.picker(s: any, machines: { any }, a: Alert, opts: { running: boolean? }?): Picker
	local running = opts ~= nil and opts.running == true
	local needed = if a.kind == "wake_blocked" and s.wake_blocked then s.wake_blocked.needed or 0 else 0
	local more_than = if a.kind == "disk" and s.disk then s.disk.capacity else nil
	local rows: { Row } = {}
	local fits = 0
	for _, m in machines do
		local too_small = m.disk_gb < needed or (more_than ~= nil and m.disk_gb <= more_than)
		local current = m.id == s.machine
		local reason: string? = nil
		if too_small then
			reason = say("holds", `holds {M.holds_gb(m.disk_gb)} GB`, { gb = M.holds_gb(m.disk_gb) })
		elseif current then
			reason = say("current", "current size")
		elseif running and s.state == "ready" then
			reason = say("after_turn", "after this turn")
		end
		if not too_small and not current then
			fits += 1
		end
		table.insert(rows, {
			id = m.id,
			name = M.machine_name(m),
			specs = M.specs(m),
			rate = say("rate", `{M.rate(m.rate)} credits`, { rate = M.rate(m.rate) }),
			current = current,
			disabled = reason ~= nil,
			reason = reason,
		})
	end
	local none_fit = fits == 0
	if none_fit and a.kind == "wake_blocked" then
		local needs = M.needs_gb(s.wake_blocked and s.wake_blocked.needed or 0)
		return {
			rows = rows,
			none_fit = true,
			body = say("blocked_body_none", `This chat's machine can't wake: it needs {needs} GB of disk.`, { needs = needs }),
			note = say("none_fit", `No machine holds the {needs} GB this chat needs. You can carry on in a new chat from what's pushed; this chat and its files stay as they are.`, { needs = needs }),
			action = "new_chat",
			action_label = say("new_chat", "Start a new chat"),
		}
	elseif none_fit then
		return { rows = rows, none_fit = true, note = say("none_bigger", "This is the biggest machine there is. Removing files is the way to free up room.") }
	end
	return {
		rows = rows,
		none_fit = false,
		note = if a.kind == "disk" and s.state == "ready" then say("restart_note", "Picking a size restarts the machine on it, with its files.") else nil,
	}
end

-- A size's choice in Settings → Cloud's default.
function M.default_options(machines: { any }): { { value: string, label: string, description: string } }
	local out = {}
	for _, m in machines do
		table.insert(out, {
			value = m.id,
			label = M.machine_name(m),
			description = say("default_option", `{M.specs(m)} · {M.rate(m.rate)} credits`, { specs = M.specs(m), rate = M.rate(m.rate) }),
		})
	end
	return out
end

-- ── Dismissal ──────────────────────────────────────────────────────────────
--
-- `map`: chat -> kind -> the level it was put away at. Plain data, so whatever
-- holds it (a persisted state) can.

-- Put away at this level, or a worse one?
function M.dismissed(map: { [string]: { [string]: string } }, chat: string, kind: string, level: string): boolean
	local put = map[chat] and map[chat][kind]
	return put ~= nil and M.rank(level) <= M.rank(put)
end

-- The map with this alert put away.
function M.dismiss(map: { [string]: { [string]: string } }, chat: string, kind: string, level: string): { [string]: { [string]: string } }
	local next_map = table.clone(map)
	local kinds = table.clone(map[chat] or {})
	kinds[kind] = level
	next_map[chat] = kinds
	return next_map
end

-- The map as a session's levels stand now, or the same map if nothing moved.
-- A level that fell lowers what's remembered, so rising back to where it was
-- put away isn't new, and rising past that is; all clear forgets it, so a
-- disk filling up again warns again.
function M.settle(map: { [string]: { [string]: string } }, s: any, now: number): { [string]: { [string]: string } }
	local kinds = map[s.chat]
	if not kinds then
		return map
	end
	local level_now = {
		disk = if s.disk then s.disk.level else nil,
		expiring = M.expiry_level(s, now),
	}
	local changed = false
	local kept = {}
	for kind, put in kinds do
		local level = level_now[kind]
		if M.rank(level) == 0 then
			changed = true
		elseif M.rank(level) < M.rank(put) then
			changed = true
			kept[kind] = level
		else
			kept[kind] = put
		end
	end
	if not changed then
		return map
	end
	local next_map = table.clone(map)
	next_map[s.chat] = if next(kept) ~= nil then kept else nil
	return next_map
end

return M
