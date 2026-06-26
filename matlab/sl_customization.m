function sl_customization(cm)
    % 在 Simulink 编辑器的 Tools 菜单加一个 "MATLAB Copilot" 入口,点了就打开侧边栏。
    % Tools 菜单是文档化、稳定的兜底入口。
    %
    % 工具条(ribbon)上的 COPILOT 选项卡按钮见 install_toolstrip.m(官方 JSON 插件架构),
    % 运行一次 install_toolstrip 即可安装。两种入口可并存。
    %
    % 启用本菜单:把本文件所在的 matlab/ 目录加入路径后,运行 sl_refresh_customizations。
    % 注:不要直接在命令窗口调用本函数 — Simulink 启动时会自动以 cm 参数调用它。
    if nargin < 1
        sl_refresh_customizations();  % 直接调用时刷新即可
        return;
    end
    cm.addCustomMenuFcn('Simulink:ToolsMenu', @getCopilotMenuItems);
    % 画布右键菜单:选中模块后右键即可「用 Copilot 解释此模块」(就地入口)。
    cm.addCustomMenuFcn('Simulink:PreContextMenu', @getCopilotContextItems);
end

function schemas = getCopilotMenuItems(~)
    schemas = {@copilotActionSchema};
end

function schema = copilotActionSchema(~)
    schema = sl_action_schema;
    schema.label = 'MATLAB Copilot';
    schema.callback = @(~) copilot();
end

function schemas = getCopilotContextItems(~)
    schemas = {@copilotExplainBlockSchema};
end

function schema = copilotExplainBlockSchema(~)
    schema = sl_action_schema;
    schema.label = '用 Copilot 解释此模块';
    schema.callback = @(~) matlabcopilot.Panel.explainActiveSelection();
end
