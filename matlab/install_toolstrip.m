function install_toolstrip()
    % INSTALL_TOOLSTRIP  在 Simulink 工具条(ribbon)上安装一个 "COPILOT" 自定义选项卡。
    %
    % 用官方文档化的 JSON 插件架构(slCreateToolstripComponent / slReloadToolstripConfig),
    % 不依赖未公开 API。安装后打开任意 Simulink 模型即可在工具条看到 COPILOT 选项卡,
    % 点 "打开 Copilot" 按钮会调用 copilot() 打开侧边栏。
    %
    %   install_toolstrip          % 安装/刷新
    %   slDestroyToolstripComponent("matlabcopilot")   % 卸载
    %
    % 参考:https://www.mathworks.com/help/simulink/ug/create-custom-simulink-toolstrip-tabs.html

    % exist(...,'file') 只匹配 .m 文件；P-file/内置函数用 exist() 无参数形式
    if exist('slCreateToolstripComponent') == 0
        error('matlabcopilot:noToolstripApi', ...
            ['未找到 slCreateToolstripComponent。\n' ...
             '请确认 Simulink 已安装且 R2021b 及以上；R2025b 下如仍报此错，\n' ...
             '可改用 Simulink 工具条插件 JSON 架构——运行 install_toolstrip 前先联系 MathWorks 确认 API 名称。']);
    end

    here = fileparts(mfilename('fullpath'));
    comp = "matlabcopilot";

    % 1. 创建组件(生成 resources/ 与 sl_toolstrip_plugins.json)。已存在则复用。
    pluginsFile = fullfile(here, 'resources', 'sl_toolstrip_plugins.json');
    if exist(pluginsFile, 'file') ~= 2
        slCreateToolstripComponent(comp, Location=here);
    end

    % 2. 生成紫色图标(16/24px PNG)到 resources/icons。
    iconDir = fullfile(here, 'resources', 'icons');
    if ~isfolder(iconDir); mkdir(iconDir); end
    writeIcon(fullfile(iconDir, 'copilot_16.png'), 16);
    writeIcon(fullfile(iconDir, 'copilot_24.png'), 24);

    % 3. 写入(覆盖)tab 与 action 定义,内容可控、可版本管理。
    jsonDir = fullfile(here, 'resources', 'json');
    if ~isfolder(jsonDir); mkdir(jsonDir); end
    writeJsonUtf8(fullfile(jsonDir, 'copilotTab.json'), tabSpec());
    writeJsonUtf8(fullfile(jsonDir, 'copilotTab_actions.json'), actionSpec());

    % 3. 上路径并重载工具条配置。
    addpath(here);
    slReloadToolstripConfig();

    fprintf(['已安装 COPILOT 工具条选项卡。打开任意 Simulink 模型查看。\n' ...
             '卸载:slDestroyToolstripComponent("%s")\n'], comp);
end

% --- tab 布局:COPILOT 选项卡 / Assistant 段 / 一个按钮 -----------------------
function spec = tabSpec()
    btnOpen = struct('type', 'PushButton', 'action', 'copilotOpenAction');
    col     = struct('type', 'Column', 'children', {{btnOpen}});
    section = struct('type', 'Section', 'title', 'Assistant', 'children', {{col}});
    tab     = struct('type', 'Tab', 'id', 'copilotTab', 'title', 'COPILOT', ...
                     'children', {{section}});
    spec    = struct('version', '1.0', 'entries', {{tab}});
end

% --- 自定义动作:command 指向要 feval 的函数名(不含路径/扩展名)----------------
function spec = actionSpec()
    % 注:光标处生成(ask_at_cursor)是面板内的快捷动作,需面板已打开并操作活动编辑器,
    % 不适合做成独立工具条按钮,故工具条只提供"打开 Copilot"入口。
    open = struct('type', 'Action', 'id', 'copilotOpenAction', ...
        'text', sprintf('打开\nCopilot'), ...
        'description', '打开 MATLAB/Simulink Copilot 侧边栏', ...
        'command', 'copilot', 'commandType', 'Callback', 'icon', 'copilotIcon');
    iconObj = struct('type', 'Icon', 'id', 'copilotIcon', ...
        'icon16', 'copilot_16.png', 'icon24', 'copilot_24.png');
    spec = struct('version', '1.0', 'entries', {{open, iconObj}});
end

% --- 生成紫色 Copilot 图标(紫底 + 白色四角星),透明圆角 --------------------
function writeIcon(file, n)
    purple = reshape([124 92 255] / 255, 1, 1, 3);   % 品牌紫 #7c5cff
    img = repmat(purple, n, n);
    [X, Y] = meshgrid(1:n, 1:n);
    c = (n + 1) / 2; dx = X - c; dy = Y - c;
    r = (n - 1) / 2;
    % 四角星(两个旋转方块的并集)做白色前景
    star = (abs(dx) + abs(dy) <= n * 0.34) | (max(abs(dx), abs(dy)) <= n * 0.16);
    for k = 1:3
        ch = img(:, :, k); ch(star) = 1; img(:, :, k) = ch;
    end
    % 圆角矩形 alpha(标准 rounded-rect 距离场):角落透明。
    rr = n * 0.24;
    qx = max(abs(dx) - (r - rr), 0); qy = max(abs(dy) - (r - rr), 0);
    alpha = double(hypot(qx, qy) <= rr);
    imwrite(img, file, 'Alpha', alpha);
end

% --- 以 UTF-8 写出 JSON(jsonencode 生成,避免手写格式错误)--------------------
function writeJsonUtf8(file, spec)
    txt = jsonencode(spec, PrettyPrint=true);
    fid = fopen(file, 'w', 'n', 'UTF-8');
    if fid < 0
        error('matlabcopilot:writeFail', '无法写入 %s', file);
    end
    cleanup = onCleanup(@() fclose(fid));
    fwrite(fid, unicode2native(txt, 'UTF-8'));
end
