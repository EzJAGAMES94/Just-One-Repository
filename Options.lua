-- ========================================
-- CORE DEOBFUSCATOR ENGINE
-- ========================================

local Deobfuscator = {}

-- 1. Decodificar escapes hexadecimais e decimais
function Deobfuscator.decodeEscapes(str)
    if type(str) ~= "string" then return str end
    -- Hex escapes: \x41 -> A
    str = str:gsub("\\x([0-9a-fA-F][0-9a-fA-F])", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    -- Decimal escapes: \065 -> A
    str = str:gsub("\\([0-9][0-9][0-9]?)", function(dec)
        local n = tonumber(dec)
        if n and n <= 255 then
            return string.char(n)
        end
        return "\\" .. dec
    end)
    -- Multi-byte decimal: \103\049\053 etc
    str = str:gsub("(\\.+)([0-9])", function(a, b) return a .. b end)
    -- Unicode \uXXXX
    str = str:gsub("\\u([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])", function(hex)
        local cp = tonumber(hex, 16)
        if cp then
            return utf8 and utf8.char(cp) or "\\u" .. hex
        end
        return "\\u" .. hex
    end)
    return str
end

-- 2. Resolver concatenações simples de strings
function Deobfuscator.resolveConcat(str)
    if type(str) ~= "string" then return str end
    -- Tenta resolver chunks de strings concatenadas entre aspas
    str = str:gsub('("[^"]*"%s*%.%s*"[^"]*")', function(s)
        -- Avaliação segura - concatena as strings
        local parts = {}
        for part in s:gmatch('"([^"]*)"') do
            table.insert(parts, part)
        end
        return '"' .. table.concat(parts) .. '"'
    end)
    return str
end

-- 3. Renomear variáveis ofuscadas (padrão: letras L/i/n)
function Deobfuscator.renameObfuscatedVars(code)
    if type(code) ~= "string" then return code end
    
    local varCounter = 0
    local varMap = {}
    local varPattern = "[lL1iI]+"
    
    -- Encontra nomes ofuscados em declarações local
    local newCode = code:gsub("local%s+(" .. varPattern .. ")", function(varName)
        if not varMap[varName] then
            varCounter = varCounter + 1
            varMap[varName] = "v" .. varCounter
        end
        return "local " .. varMap[varName]
    end)
    
    -- Substitui usos das variáveis (cuidado para não pegar palavras-chave)
    for oldName, newName in pairs(varMap) do
        newCode = newCode:gsub("([^%w_])" .. oldName .. "([^%w_])", "%1" .. newName .. "%2")
    end
    
    return newCode
end

-- 4. Remover wrappers de execução comuns
function Deobfuscator.removeExecutionWrappers(code)
    if type(code) ~= "string" then return code end
    
    -- Remover loadstring() wrappers: loadstring("...")()
    code = code:gsub("loadstring%s*%(([^)]+)%)%s*%(%s*%)", function(inner)
        return inner
    end)
    
    -- Remover (function(...) ... end)(params)
    code = code:gsub("%(%s*function%s*%([^)]*%)[^=]-end%s*%)%s*%([^)]*%)", function(full)
        -- Tentar extrair o corpo da função
        local body = full:match("function%s*%([^)]*%)(.-)end")
        if body then
            return body
        end
        return full
    end)
    
    return code
end

-- 5. Identificar e extrair payload de loadstring
function Deobfuscator.extractLoadstringPayload(code)
    if type(code) ~= "string" then return code, false end
    
    local extracted = false
    local newCode = code:gsub('loadstring%(([^)]+)%)', function(inner)
        -- Tenta extrair string literal
        local str = inner:match('"(.-)"') or inner:match("'(.-)'") or inner:match("%[%[(.-)%]%]")
        if str then
            extracted = true
            return "--[[ LOADSTRING PAYLOAD EXTRACTED ]]\n" .. Deobfuscator.decodeEscapes(str)
        end
        return "loadstring(" .. inner .. ")"
    end)
    
    return newCode, extracted
end

-- 6. Expandir shorthand Lua (tabelas de lookup)
function Deobfuscator.resolveTableLookups(code)
    if type(code) ~= "string" then return code end
    
    -- Tenta simplificar padrões como _G['print'] -> print
    code = code:gsub("_G%[['\"]([%w_]+)['\"]%]", "%1")
    
    -- Resolver _G[string_var]
    return code
end

-- 7. Formatador / Beautifier completo
function Deobfuscator.beautify(code)
    if type(code) ~= "string" then return code end
    
    -- Adicionar nova linha após pontos finais
    code = code:gsub("(%w)%.(%w)", function(a, b)
        if a:match("^[a-zA-Z_][a-zA-Z0-9_]*$") and b:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
            return a .. "." .. b
        end
        return a .. "." .. b
    end)
    
    -- Nova linha após fechamento de bloco
    code = code:gsub("end%s*([^%s])", "end\n%1")
    code = code:gsub("end%s*$", "end\n")
    
    -- Indentação básica
    local indent_level = 0
    local indent_str = "    "
    local lines = {}
    for line in code:gmatch("[^\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if not trimmed or trimmed == "" then
            goto continue
        end
        
        -- Reduz indentação se fechando bloco
        if trimmed:match("^end") or trimmed:match("^else") or trimmed:match("^elseif") or trimmed:match("^until") then
            indent_level = math.max(0, indent_level - 1)
        end
        
        table.insert(lines, string.rep(indent_str, indent_level) .. trimmed)
        
        -- Aumenta indentação se abrindo bloco
        local opens = 0
        for _ in trimmed:gmatch("then%s*$") do opens = opens + 1 end
        for _ in trimmed:gmatch("do%s*$") do opens = opens + 1 end
        for _ in trimmed:gmatch("function") do
            -- Só se for function declaration, não call
            if trimmed:match("function%s*[%w_%.]+%s*%(") or trimmed:match("function%s*%(") then
                opens = opens + 1
            end
        end
        for _ in trimmed:gmatch("repeat") do opens = opens + 1 end
        for _ in trimmed:gmatch("if%s.*then") do opens = opens + 1 end
        for _ in trimmed:gmatch("else$") do opens = opens + 1 end
        for _ in trimmed:gmatch("elseif") do opens = opens + 1 end
        
        indent_level = indent_level + opens
        
        ::continue::
    end
    
    return table.concat(lines, "\n")
end

-- 8. Pipeline principal de desofuscação
function Deobfuscator.deobfuscate(code)
    if type(code) ~= "string" then
        return nil, "Input must be a string"
    end
    
    if code:len() == 0 then
        return nil, "Empty script"
    end
    
    local result = code
    local steps = {}
    
    -- Step 1: Extrair payloads de loadstring
    result, _ = Deobfuscator.extractLoadstringPayload(result)
    table.insert(steps, "Extraído payload de loadstring")
    
    -- Step 2: Decodificar escapes hex/dec
    result = Deobfuscator.decodeEscapes(result)
    table.insert(steps, "Escapes hexadecimais/decimais decodificados")
    
    -- Step 3: Remover wrappers de execução
    result = Deobfuscator.removeExecutionWrappers(result)
    table.insert(steps, "Wrappers de execução removidos")
    
    -- Step 4: Resolver concatenações
    result = Deobfuscator.resolveConcat(result)
    table.insert(steps, "Concatenações resolvidas")
    
    -- Step 5: Renomear variáveis ofuscadas
    result = Deobfuscator.renameObfuscatedVars(result)
    table.insert(steps, "Variáveis ofuscadas renomeadas")
    
    -- Step 6: Resolver lookup de tabelas
    result = Deobfuscator.resolveTableLookups(result)
    table.insert(steps, "Table lookups resolvidos")
    
    -- Step 7: Beautify
    result = Deobfuscator.beautify(result)
    table.insert(steps, "Código formatado/indentado")
    
    return result, steps
end

-- ========================================
-- INTERFACE GRÁFICA 
-- ========================================

-- Detectar qual library de UI está disponível
local UI

if syn and syn.protect_gui then
    -- Synapse X / Scriptware
    UI = {
        new = {
            Window = function(...)
                local w = syn.protect_gui(game:GetObjects("rbxassetid://4483349576")[1])
                return w
            end,
            Frame = function(parent)
                local f = Instance.new("Frame")
                f.Parent = parent
                return f
            end,
            TextLabel = function(parent)
                local l = Instance.new("TextLabel")
                l.Parent = parent
                return l
            end,
            TextBox = function(parent)
                local tb = Instance.new("TextBox")
                tb.Parent = parent
                return tb
            end,
            ScrollingFrame = function(parent)
                local sf = Instance.new("ScrollingFrame")
                sf.Parent = parent
                return sf
            end,
            TextButton = function(parent)
                local btn = Instance.new("TextButton")
                btn.Parent = parent
                return btn
            end
        },
        Colors = {
            Background = Color3.fromRGB(25, 25, 35),
            Surface = Color3.fromRGB(35, 35, 50),
            Primary = Color3.fromRGB(0, 170, 255),
            Text = Color3.fromRGB(230, 230, 240),
            Success = Color3.fromRGB(0, 200, 100),
            Error = Color3.fromRGB(255, 80, 80),
            Accent = Color3.fromRGB(100, 100, 255)
        }
    }
elseif game:GetService("CoreGui"):FindFirstChild("RobloxGui") then
    -- Usar CoreGui padrão (mais simples)
    UI = {
        new = {
            Window = function(title, size)
                local gui = Instance.new("ScreenGui")
                gui.Name = "DeobfuscatorGUI"
                gui.Parent = (syn and syn.protect_gui and game:GetService("CoreGui")) or game:GetService("CoreGui")
                
                local bg = Instance.new("Frame")
                bg.Size = UDim2.fromOffset(size.X, size.Y)
                bg.Position = UDim2.new(0.5, -size.X/2, 0.5, -size.Y/2)
                bg.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
                bg.BorderSizePixel = 0
                bg.Active = true
                bg.Draggable = true
                bg.Parent = gui
                
                local titleBar = Instance.new("Frame")
                titleBar.Size = UDim2.new(1, 0, 0, 35)
                titleBar.BackgroundColor3 = Color3.fromRGB(15, 15, 25)
                titleBar.BorderSizePixel = 0
                titleBar.Parent = bg
                
                local titleLbl = Instance.new("TextLabel")
                titleLbl.Size = UDim2.new(1, 0, 1, 0)
                titleLbl.BackgroundTransparency = 1
                titleLbl.Text = title
                titleLbl.TextColor3 = Color3.fromRGB(230, 230, 240)
                titleLbl.Font = Enum.Font.GothamBold
                titleLbl.TextSize = 16
                titleLbl.Parent = titleBar
                
                return gui, bg
            end,
            MultiLineTextBox = function(parent, pos, size)
                local frame = Instance.new("Frame")
                frame.Position = pos
                frame.Size = size
                frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
                frame.BorderSizePixel = 0
                frame.Parent = parent
                
                local box = Instance.new("TextBox")
                box.Size = UDim2.new(1, -10, 1, -10)
                box.Position = UDim2.new(0, 5, 0, 5)
                box.BackgroundColor3 = Color3.fromRGB(15, 15, 22)
                box.TextColor3 = Color3.fromRGB(200, 200, 210)
                box.Font = Enum.Font.Code
                box.TextSize = 13
                box.TextWrapped = false
                box.TextXAlignment = Enum.TextXAlignment.Left
                box.TextYAlignment = Enum.TextYAlignment.Top
                box.ClearTextOnFocus = false
                box.MultiLine = true
                box.Parent = frame
                
                -- Scrollbar
                local scrolling = Instance.new("ScrollingFrame")
                scrolling.Size = UDim2.new(1, 0, 1, 0)
                scrolling.BackgroundTransparency = 1
                scrolling.ScrollBarThickness = 8
                scrolling.CanvasSize = UDim2.new(0, 0, 2, 0)
                scrolling.Parent = frame
                
                box.Parent = scrolling
                
                return frame, box, scrolling
            end,
            Button = function(parent, pos, size, text, color, textColor)
                local btn = Instance.new("TextButton")
                btn.Position = pos
                btn.Size = size
                btn.Text = text
                btn.BackgroundColor3 = color or Color3.fromRGB(0, 120, 200)
                btn.TextColor3 = textColor or Color3.fromRGB(255, 255, 255)
                btn.Font = Enum.Font.GothamBold
                btn.TextSize = 14
                btn.BorderSizePixel = 0
                btn.Parent = parent
                return btn
            end,
            Label = function(parent, pos, size, text)
                local lbl = Instance.new("TextLabel")
                lbl.Position = pos
                lbl.Size = size
                lbl.Text = text
                lbl.BackgroundTransparency = 1
                lbl.TextColor3 = Color3.fromRGB(180, 180, 195)
                lbl.Font = Enum.Font.Gotham
                lbl.TextSize = 12
                lbl.TextXAlignment = Enum.TextXAlignment.Left
                lbl.Parent = parent
                return lbl
            end
        }
    }
else
    UI = nil
end

-- ========================================
-- INICIALIZAÇÃO DA GUI
-- ========================================

local function createDeobfuscatorGUI()
    if not UI then
        warn("Deobfuscator: No compatible UI library found. Using console mode.")
        return nil
    end
    
    pcall(function()
        game:GetService("CoreGui"):FindFirstChild("DeobfuscatorGUI"):Destroy()
    end)
    
    local gui, bg = UI.new.Window("Roblox Script Deobfuscator v2.0", Vector2.new(720, 520))
    gui.Name = "DeobfuscatorGUI"
    
    local currentBg = bg or gui:FindFirstChildOfClass("Frame") or gui
    
    -- Input area
    local inputLbl = UI.new.Label(currentBg, UDim2.new(0, 15, 0, 45), UDim2.new(0, 200, 0, 20), 
        "▸ Código Ofuscado (input):")
    
    local inputFrame, inputBox, inputScroll = UI.new.MultiLineTextBox(currentBg, 
        UDim2.new(0, 15, 0, 68), UDim2.new(1, -30, 0, 180))
    
    if inputBox then
        inputBox.PlaceholderText = "Cole o script ofuscado aqui..."
        inputBox.Text = ""
    end
    
    -- Output area
    local outputLbl = UI.new.Label(currentBg, UDim2.new(0, 15, 0, 258), UDim2.new(0, 200, 0, 20),
        "▸ Código Deobfuscado (output):")
    
    local outputFrame, outputBox, outputScroll = UI.new.MultiLineTextBox(currentBg,
        UDim2.new(0, 15, 0, 280), UDim2.new(1, -30, 0, 180))
    
    if outputBox then
        outputBox.ReadOnly = true
        outputBox.PlaceholderText = "Resultado aparecerá aqui..."
        outputBox.TextColor3 = Color3.fromRGB(0, 220, 120)
    end
    
    -- Status bar
    local statusLbl = UI.new.Label(currentBg, UDim2.new(0, 15, 0, 468), UDim2.new(1, -200, 0, 20),
        "✓ Pronto para deobfuscar.")
    
    -- Buttons
    local deobfBtn = UI.new.Button(currentBg, 
        UDim2.new(0, 15, 0, 490), UDim2.new(0, 160, 0, 30),
        "▶ DEOBFUSCAR", Color3.fromRGB(0, 150, 60))
    
    local copyBtn = UI.new.Button(currentBg,
        UDim2.new(0, 190, 0, 490), UDim2.new(0, 160, 0, 30),
        "📋 COPIAR", Color3.fromRGB(0, 100, 200))
    
    local clearBtn = UI.new.Button(currentBg,
        UDim2.new(0, 365, 0, 490), UDim2.new(0, 100, 0, 30),
        "LIMPAR", Color3.fromRGB(150, 50, 50))
    
    local closeBtn = UI.new.Button(currentBg,
        UDim2.new(1, -75, 0, 5), UDim2.new(0, 65, 0, 25),
        "✕ FECHAR", Color3.fromRGB(180, 40, 40))
    
    -- Info label
    if UI.new.Label then
        UI.new.Label(currentBg, UDim2.new(0, 480, 0, 493), UDim2.new(0, 230, 0, 24),
            "Roblox Deobfuscator | Autorizado para Pentest")
    end
    
    -- Button handlers
    deobfBtn.MouseButton1Click:Connect(function()
        local input = inputBox and inputBox.Text or ""
        if not input or input == "" then
            statusLbl.Text = "⚠ Erro: Nenhum script inserido!"
            return
        end
        
        statusLbl.Text = "⏳ Deobfuscando..."
        
        local success, err = pcall(function()
            local result, steps = Deobfuscator.deobfuscate(input)
            
            if result then
                if outputBox then
                    outputBox.Text = result
                end
                
                -- Atualizar status com passos realizados
                local stepsText = ""
                if type(steps) == "table" then
                    stepsText = " | " .. table.concat(steps, " • ")
                end
                
                local sizeBefore = #input
                local sizeAfter = #result
                local reduction = math.floor((1 - sizeAfter / math.max(sizeBefore, 1)) * 100)
                
                statusLbl.Text = string.format("✓ Deobfuscação concluída! %d → %d chars (%d%% redução)%s",
                    sizeBefore, sizeAfter, math.max(0, reduction), stepsText)
            else
                statusLbl.Text = "⚠ Erro durante deobfuscação"
            end
        end)
        
        if not success then
            statusLbl.Text = "✗ Erro: " .. tostring(err)
        end
    end)
    
    copyBtn.MouseButton1Click:Connect(function()
        local textToCopy = outputBox and outputBox.Text or ""
        if textToCopy == "" then
            statusLbl.Text = "⚠ Nada para copiar!"
            return
        end
        
        local success, err = pcall(function()
            -- Tentar setclipboard() (comum em executors)
            if setclipboard then
                setclipboard(textToCopy)
            elseif set_clipboard then
                set_clipboard(textToCopy)
            elseif clipboard then
                clipboard.set(textToCopy)
            elseif syn and syn.set_clipboard then
                syn.set_clipboard(textToCopy)
            else
                -- Fallback: tentar com toclipboard
                local f = Instance.new("ScreenGui")
                f.Parent = game:GetService("CoreGui")
                local tb = Instance.new("TextBox")
                tb.Text = textToCopy
                tb:CaptureFocus()
                tb:ReleaseFocus()
                f:Destroy()
                
                -- Tentar API nativa do executor
                if not pcall(function()
                    -- Para executors com método clipboard
                    local clip = getgenv().clipboard or getgenv().setclipboard
                    if clip then clip(textToCopy) end
                end) then
                    statusLbl.Text = "⚠ setclipboard() não disponível nesse executor"
                    return
                end
            end
            statusLbl.Text = "✓ Copiado para área de transferência! (" .. #textToCopy .. " chars)"
        end)
        
        if not success then
            statusLbl.Text = "✗ Erro ao copiar: " .. tostring(err)
        end
    end)
    
    clearBtn.MouseButton1Click:Connect(function()
        if inputBox then inputBox.Text = "" end
        if outputBox then outputBox.Text = "" end
        statusLbl.Text = "✓ Campos limpos. Pronto para deobfuscar."
    end)
    
    closeBtn.MouseButton1Click:Connect(function()
        gui:Destroy()
        -- Se tiver console, mostrar mensagem final
        if rconsoleprint then
            rconsoleprint("Deobfuscator encerrado.\n")
        end
    end)
    
    -- Função para permitir Ctrl+C via código (não nativo, mas por input)
    -- Output click to select all
    if outputBox then
        outputBox.FocusLost:Connect(function()
            -- Não faz nada especial, o usuário pode selecionar manualmente
        end)
    end
    
    return gui
end

-- ========================================
-- FUNÇÃO ÚNICA: deobfuscar scripting API
-- ========================================

function deobfuscateScript(scriptCode)
    return Deobfuscator.deobfuscate(scriptCode)
end

-- ========================================
-- INICIAR
-- ========================================

-- Iniciar GUI
local success = pcall(createDeobfuscatorGUI)

if not success then
    -- Fallback: modo console/texto
    print("=== Roblox Deobfuscator - Modo Console ===")
    print("Autorizado para pentest em ambiente controlado")
    print("")
    print("Para usar a interface GUI, cole este script em um executor")
    print("com suporte a UI (Synapse X, Scriptware, Krnl, etc.)")
    print("")
    print("=== Uso Programático ===")
    print([[local result, steps = deobfuscateScript(obfuscatedCode)]])
    print("")
    
    -- Se tiver rconsole, usar
    if rconsoleprint then
        rconsoleprint("=== Roblox Deobfuscator - Modo Console ===\n")
        rconsoleprint("GUI não disponível. Use a função deobfuscateScript()\n")
    end
end

-- Retornar o módulo para uso programático
return Deobfuscator
