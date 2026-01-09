type table = {[any]:any}
type RemoteData = {Remote:Instance,IsReceive:boolean?,MetaMethod:string,Args:table,Method:string,TransferType:string,ValueReplacements:table,NoVariables:boolean?}

local Generation = {
    DumpBaseName = "SigmaSpy-Dump %s.lua",
    Header = "-- Generated with Sigma Spy",
    ScriptTemplates = {
        ["Remote"] = {{"%RemoteCall%"}},
        ["Spam"] = {{"while wait() do"},{"%RemoteCall%",2},{"end"}},
        ["Repeat"] = {{"for Index = 1, 10 do"},{"%RemoteCall%",2},{"end"}},
        ["Block"] = {
            ["__index"] = {
                {"local Old; Old = hookfunction(%Signal%, function(self, ...)"},
                {"if self == %Remote% then",2},{"return",3},{"end",2},
                {"return Old(self, ...)",2},{"end)"}
            },
            ["__namecall"] = {
                {"local Old; Old = hookmetamethod(game, \"__namecall\", function(self, ...)"},
                {"local Method = getnamecallmethod()",2},
                {"if self == %Remote% and Method == \"%Method%\" then",2},
                {"return",3},{"end",2},{"return Old(self, ...)",2},{"end)"}
            },
            ["Connect"] = {
                {"for _, Connection in getconnections(%Signal%) do"},
                {"Connection:Disable()",2},{"end"}
            }
        }
    }
}

local Config, Hook, ParserModule, Flags, ThisScript = nil,nil,nil,nil,script

local function Merge(Base,New)
    if not New then return end
    for k,v in next,New do Base[k]=v end
end

function Generation:Init(Data)
    local M = Data.Modules
    local C = M.Configuration
    Config = M.Config
    Hook = M.Hook
    Flags = M.Flags

    ParserModule = loadstring(game:HttpGet(C.ParserUrl),"Parser")()
    ParserModule.Modules = ParserModule.Modules or {}
    ParserModule.Modules.Formatter = loadstring(game:HttpGet("https://raw.githubusercontent.com/zzz141632-png/parser/refs/heads/main/Formatter.lua"))()
    ParserModule.Modules.Parser    = loadstring(game:HttpGet("https://raw.githubusercontent.com/zzz141632-png/parser/refs/heads/main/Parser.lua"))()
    ParserModule.Modules.Variables = ParserModule.Modules.Parser
end

function Generation:MakePrintable(s) return ParserModule.Modules.Formatter:MakePrintable(s) end

function Generation:MakeValueSwapsTable() return ParserModule.Modules.Formatter:MakeReplacements() end

function Generation:SetSwapsCallback(cb) self.SwapsCallback=cb end

function Generation:GetBase(m)
    local nc = Flags:GetFlagValue("NoComments")
    local code = nc and "" or self.Header
    local vars = m.Parser:MakeVariableCode({"Services","Remote","Variables"},nc)
    local novars = vars==""
    code ..= vars
    return code,novars
end

function Generation:GetSwaps()
    local f = self.SwapsCallback
    local swaps = {}
    local i = {}
    function i:AddSwap(o,d) if o then swaps[o]=d end end
    f(i)
    return swaps
end

function Generation:PickVariableName()
    local n = Config.VariableNames
    return n[math.random(1,#n)]
end

function Generation:NewParser(extra)
    local vn = self:PickVariableName()
    local s = self:GetSwaps()
    local cfg = {VariableBase=vn,Swaps=s,IndexFunc=function(...)return Hook:Index(...)end}
    Merge(cfg,extra)
    return ParserModule:New(cfg)
end

function Generation:Indent(is,line) return `{is}{line}` end

function Generation:MakeIndent(n) return string.rep(" ",n) end

function Generation:ApplyVariables(s,vars,...)
    for k,v in vars do
        if type(v)=="function" then v=v(...) end
        s = s:gsub("%%"..k.."%%",v)
    end
    return s
end

function Generation:CallRemoteScript(d,info)
    local ir = d.IsReceive
    local m = d.Method
    local a = d.Args
    local rv = info.RemoteVariable
    local ind = info.Indent or 0
    local mod = info.Module
    local vars = mod.Variables
    local p = mod.Parser
    local nv = d.NoVariables
    local is = self:MakeIndent(ind)
    local pa,ic,ia = p:ParseTableIntoString({NoBrackets=true,NoVariables=nv,Table=a,Indent=ind})
    if not ia or nv then
        pa = vars:MakeVariable({Value=("{%s}"):format(pa),Comment=not ia and "Arguments aren't ordered",Name="RemoteArgs",Class="Remote"})
    end
    if ic>0 and not ia then pa=`unpack({pa},1,table.maxn({pa}))` end
    if ir then
        local sec = ic<=0 and "" or `, {pa}`
        return `-- This data was received from the server\n{is}firesignal({rv}.{m}{sec})`
    end
    return `{rv}:{m}({pa})`
end

function Generation:MakeCallCode(st,dat)
    local t = self.ScriptTemplates[st]
    assert(t,"Invalid script type")
    local v = dat.Variables
    local mm = dat.MetaMethod
    local mms = {"__index","__namecall","Connect"}
    local function comp(t)
        local out=""
        for k,val in next,t do
            if table.find(mms,k) then
                if k==mm then out ..= comp(val) end
                continue
            end
            local c,i = val[1],val[2] or 0
            i=math.clamp(i-1,0,9999)
            local l = self:ApplyVariables(c,v,i)
            local is = self:MakeIndent(i)
            out ..= `{is}{l}\n`
        end
        return out
    end
    return comp(t)
end

function Generation:RemoteScript(m,d,st)
    local r = d.Remote
    local a = d.Args
    local meth = d.Method
    local metam = d.MetaMethod
    local cn = Hook:Index(r,"ClassName")
    local nilp = Hook:Index(r,"Parent")==nil
    local v = m.Variables
    local f = m.Formatter
    v:PrerenderVariables(a,{"Instance"})
    local rv = v:MakeVariable({Value=f:Format(r,{NoVariables=true}),Comment=`{cn} {nilp and "| Remote parent is nil"}`,Name=f:MakeName(r),Lookup=r,Class="Remote"})
    local cc = self:MakeCallCode(st,{Variables={
        ["RemoteCall"]=function(ind)return self:CallRemoteScript(d,{RemoteVariable=rv,Indent=ind,Module=m})end,
        ["Remote"]=rv,["Method"]=meth,["Signal"]=`{rv}.{meth}`
    },MetaMethod=metam})
    local code = self:GetBase(m)
    return `{code}\n{cc}`
end

function Generation:ConnectionsTable(s)
    local con = getconnections(s)
    local da = {}
    for _,c in con do
        local f = c.Function
        local sc = rawget(getfenv(f),"script")
        if sc==ThisScript then continue end
        table.insert(da,{Function=f,State=c.State,Script=sc})
    end
    return da
end

function Generation:TableScript(m,t)
    m.Variables:PrerenderVariables(t,{"Instance"})
    local pt = m.Parser:ParseTableIntoString({Table=t})
    local c,nv = self:GetBase(m)
    local sep = nv and "" or "\n"
    return `{c}{sep}return {pt}`
end

function Generation:MakeTypesTable(t)
    local ty={}
    for k,v in t do
        local typ=typeof(v)
        if typ=="table" then typ=self:MakeTypesTable(v) end
        ty[k]=typ
    end
    return ty
end

function Generation:ConnectionInfo(r,cd)
    local rm = cd.Receive
    if not rm then return end
    local c={}
    for _,meth in rm do
        pcall(function()
            local sig = Hook:Index(r,meth)
            c[meth]=self:ConnectionsTable(sig)
        end)
    end
    return c
end

function Generation:AdvancedInfo(m,d)
    local f = d.CallingFunction
    local cd = d.ClassData
    local r = d.Remote
    local a = d.Args
    local fi = {
        ["Caller"]={SourceScript=d.SourceScript,CallingScript=d.CallingScript,CallingFunction=f},
        ["Remote"]={Remote=r,RemoteID=d.Id,Method=d.Method,Connections=self:ConnectionInfo(r,cd)},
        ["Arguments"]={Length=#a,Types=self:MakeTypesTable(a)},
        ["MetaMethod"]=d.MetaMethod,["IsActor"]=d.IsActor
    }
    if f and islclosure(f) then
        fi.UpValues = debug.getupvalues(f)
        fi.Constants = debug.getconstants(f)
    end
    return self:TableScript(m,fi)
end

function Generation:DumpLogs(logs)
    local bd
    local p = {Remote=nil,Calls={}}
    local m = Generation:NewParser()
    for _,d in logs do
        table.insert(p.Calls,{
            Args=d.Args,Timestamp=d.Timestamp,ReturnValues=d.ReturnValues,
            Method=d.Method,MetaMethod=d.MetaMethod,CallingScript=d.CallingScript
        })
        if not bd then bd=d end
    end
    p.Remote=bd.Remote
    local out = self:TableScript(m,p)
    return self:WriteDump(out)
end

return Generation
