-- InventoryUI — paints what the view model decided. Knows nothing about items.

-- Every string it shows arrives as an argument and every number it shows was computed
-- by ViewModel. This file has no opinion about inventory at all, which is why it can
-- be 130 lines of instance juggling with no logic worth testing.

-- Built in code rather than as a .rbxmx, for the same reason the rest of the kit is
-- files: the whole UI is reviewable in a diff.

local InventoryUI = {}

local SLOT = 54 -- slot side in pixels; 5 per row at the frame's width
local GAP = 4

local function nuevaInstancia(
	clase: string,
	props: { [string]: any },
	hijos: { Instance }?
): Instance
	local inst = Instance.new(clase)
	for k, v in pairs(props) do
		(inst :: any)[k] = v
	end
	if hijos then
		for _, h in ipairs(hijos) do
			h.Parent = inst
		end
	end
	return inst
end

--[[
	new(parent, messages, onSlotClick, onDropClick) -> { render, destroy }

	onSlotClick(index) fires on a left click on a slot; the CALLER decides what that
	means (equip or unequip) because this file does not know what equipping is.
]]
function InventoryUI.new(
	parent: Instance,
	messages: { [string]: string },
	onSlotClick: (number) -> (),
	onDropClick: (number) -> ()
): { [string]: any }
	local raiz = nuevaInstancia("ScreenGui", {
		Name = "InventoryKitUI",
		-- Without this the whole GUI is destroyed and rebuilt on every respawn, and the
		-- render loop keeps writing into a dead instance.
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		-- False on purpose. `true` pins the GUI to the very top of the screen, which
		-- puts the first row of slots UNDER Roblox's top bar: clicks there land on the
		-- CoreGUI and the console fills with "hits CoreGUI" while the slot looks fine.
		IgnoreGuiInset = false,
	}, nil)
	raiz.Parent = parent

	local marco = nuevaInstancia("Frame", {
		Name = "Panel",
		-- Top-right, not vertically centred. A centred panel is taller than a small
		-- viewport and its first rows render above the screen edge — measured at
		-- AbsolutePosition.Y = -3 in Studio, which also makes them unclickable.
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0) + UDim2.fromOffset(-16, 16),
		Size = UDim2.fromOffset(SLOT * 5 + GAP * 6 + 24, 320),
		BackgroundColor3 = Color3.fromRGB(28, 29, 34),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
	}, nil)
	marco.Parent = raiz

	nuevaInstancia("UICorner", { CornerRadius = UDim.new(0, 8) }, nil).Parent = marco

	-- Header: title, the used/max counter, and the one-line hint.
	local cabecera = nuevaInstancia("Frame", {
		Name = "Header",
		Size = UDim2.new(1, -16, 0, 46),
		Position = UDim2.fromOffset(8, 8),
		BackgroundTransparency = 1,
	}, nil)
	cabecera.Parent = marco

	local titulo = nuevaInstancia("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextColor3 = Color3.fromRGB(240, 240, 245),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = messages.uiTitle,
	}, nil)
	titulo.Parent = cabecera

	local contador = nuevaInstancia("TextLabel", {
		Name = "Counter",
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.fromOffset(0, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(150, 152, 160),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = messages.uiHint,
	}, nil)
	contador.Parent = cabecera

	-- A ScrollingFrame, not a Frame. Measured at the 200-slot ceiling: the panel came out
	-- 2390px tall inside a 252px viewport, so everything past the fifth slot was simply
	-- off-screen and unclickable.
	local rejilla = nuevaInstancia("ScrollingFrame", {
		Name = "Slots",
		Size = UDim2.new(1, -16, 1, -70),
		Position = UDim2.fromOffset(8, 62),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- CanvasSize is set explicitly in render(), NOT with AutomaticCanvasSize.
		-- Measured: with AutomaticCanvasSize the canvas stayed at 0 for a UIGridLayout, so
		-- the scrollbar had no range and everything past the visible rows was unreachable —
		-- the exact bug the ScrollingFrame was added to fix. It resizes for a UIListLayout;
		-- for a grid, count the rows yourself.
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, nil)
	rejilla.Parent = marco

	nuevaInstancia("UIGridLayout", {
		CellSize = UDim2.fromOffset(SLOT, SLOT),
		CellPadding = UDim2.fromOffset(GAP, GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, nil).Parent =
		rejilla

	-- Slots are created once and reused. Rebuilding the tree on every state would
	-- destroy the button under the player's cursor mid-click.
	local botones: { [number]: { marco: TextButton, etiqueta: TextLabel, cantidad: TextLabel, tirar: TextButton } } =
		{}

	local function crearSlot(index: number)
		local boton = nuevaInstancia("TextButton", {
			Name = "Slot" .. index,
			LayoutOrder = index,
			Size = UDim2.fromOffset(SLOT, SLOT),
			BackgroundColor3 = Color3.fromRGB(48, 50, 58),
			BorderSizePixel = 0,
			AutoButtonColor = true,
			Text = "",
		}, nil)
		boton.Parent = rejilla
		nuevaInstancia("UICorner", { CornerRadius = UDim.new(0, 5) }, nil).Parent = boton

		-- TextScaled shrinks the label to fit the slot, which stops a long id overflowing
		-- it. Two honest notes, both learned by looking at the rendered result:
		--   - Roblox still WRAPS when TextScaled is on; setting TextWrapped = false does
		--     not prevent it. That is fine here, and better than fine: what made the old
		--     label ugly was breaking a long word mid-word ("POTION_H / EALTH"), and the
		--     fix for that was giving it a display name with a space to break at.
		--   - The constraint keeps the result readable, and stops a single-item slot from
		--     rendering one enormous letter.
		local etiqueta = nuevaInstancia("TextLabel", {
			Name = "Label",
			Size = UDim2.new(1, -6, 1, -18),
			Position = UDim2.fromOffset(3, 4),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextWrapped = false,
			TextScaled = true,
			TextColor3 = Color3.fromRGB(230, 232, 238),
			Text = "",
		}, nil)
		etiqueta.Parent = boton

		local limite = nuevaInstancia("UITextSizeConstraint", {
			MaxTextSize = 11,
			MinTextSize = 6,
		}, nil)
		limite.Parent = etiqueta

		local cantidad = nuevaInstancia("TextLabel", {
			Name = "Quantity",
			Size = UDim2.new(1, -6, 0, 14),
			Position = UDim2.new(0, 3, 1, -16),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 11,
			TextColor3 = Color3.fromRGB(180, 220, 255),
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "",
		}, nil)
		cantidad.Parent = boton

		-- The drop button lives on the slot, only visible when there is something to
		-- drop. A second click target beats a right-click, which nobody discovers.
		local tirar = nuevaInstancia("TextButton", {
			Name = "Drop",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromOffset(16, 16),
			BackgroundColor3 = Color3.fromRGB(120, 52, 52),
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(255, 235, 235),
			Text = messages.uiDrop,
			Visible = false,
			ZIndex = 3,
		}, nil)
		tirar.Parent = boton
		nuevaInstancia("UICorner", { CornerRadius = UDim.new(0, 4) }, nil).Parent = tirar

		boton.MouseButton1Click:Connect(function()
			onSlotClick(index)
		end)
		tirar.MouseButton1Click:Connect(function()
			onDropClick(index)
		end)

		botones[index] = { marco = boton, etiqueta = etiqueta, cantidad = cantidad, tirar = tirar }
	end

	local mayorVisto = 0

	local function render(view: { [string]: any })
		-- Grow only. Shrinking would delete buttons a click is mid-flight on, and the
		-- state's size rarely goes down (setMaxSlots refuses to cut items off).
		if view.maxSlots > mayorVisto then
			for i = mayorVisto + 1, view.maxSlots do
				crearSlot(i)
			end
			mayorVisto = view.maxSlots
		end

		for i = 1, mayorVisto do
			local b = botones[i]
			local v = view.slots[i]
			if b and not v then
				-- The inventory shrank. This button is beyond the current size, so it has
				-- no state to render — and leaving it as it was would show a stale item in
				-- a slot that no longer exists.
				b.marco.Visible = false
			elseif b and v then
				b.marco.Visible = true
				if v.empty then
					b.etiqueta.Text = ""
					b.cantidad.Text = ""
					b.tirar.Visible = false
					b.marco.BackgroundColor3 = Color3.fromRGB(48, 50, 58)
				else
					b.etiqueta.Text = v.label
					b.cantidad.Text = if v.quantity > 1 then "x" .. v.quantity else ""
					b.tirar.Visible = true
					-- Equipped is a colour, not a word: the border already says it and a
					-- big label would cover the item name.
					b.marco.BackgroundColor3 = if v.equipped
						then Color3.fromRGB(58, 96, 74)
						else Color3.fromRGB(48, 50, 58)
				end
				if not v.ready and view.ready == false then
					b.marco.Visible = false
				end
			end
		end

		contador.Text = string.format("%d / %d   %s", view.used, view.maxSlots, view.hint)
		marco.Visible = view.ready == true

		-- Height follows the slot count, capped to the window. Without the cap a 200-slot
		-- inventory asks for a 2390px panel on a 252px viewport; the scrolling frame above
		-- makes the overflow reachable, and this keeps the panel itself on screen.
		local filas = math.max(1, math.ceil(view.maxSlots / 5))
		-- The canvas has to fit every row, or the rows past the frame are unclickable.
		rejilla.CanvasSize = UDim2.fromOffset(0, filas * (SLOT + GAP) + GAP)
		local deseado = 62 + filas * (SLOT + GAP) + 8
		local camara = workspace.CurrentCamera
		local altoVentana = if camara then camara.ViewportSize.Y else 600
		marco.Size =
			UDim2.fromOffset(SLOT * 5 + GAP * 6 + 24, math.min(deseado, altoVentana * 0.85))
	end

	return {
		render = render,
		instance = raiz,
		destroy = function()
			raiz:Destroy()
		end,
	}
end

return InventoryUI
