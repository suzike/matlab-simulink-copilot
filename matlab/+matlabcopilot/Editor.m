classdef Editor
    % 编辑器 IO 助手:读取当前光标、把代码插入光标处。
    % 同时尽量兼容普通 .m 编辑器与 Live Editor(.mlx)。

    methods (Static)
        function [doc, sel] = activeCursor()
            % 返回当前活动文档句柄与其 Selection([sl sc el ec]);无则返回空。
            doc = [];
            sel = [];
            try
                doc = matlab.desktop.editor.getActive();
                if isempty(doc); return; end
                sel = doc.Selection;
            catch
                doc = [];
                sel = [];
            end
        end

        function ok = insertAtCursor(doc, sel, text)
            % 在 doc 的 sel 起点插入 text。优先按行列插入,失败则退化为追加。
            ok = false;
            if isempty(doc) || isempty(text); return; end
            code = char(text);
            try
                if ~isempty(sel) && numel(sel) >= 2
                    doc.insertTextAtPositionInLine(code, sel(1), sel(2));
                else
                    doc.appendText(code);
                end
                ok = true;
                try, doc.makeActive(); catch, end
                return;
            catch
            end
            % 退化路径:Live Editor 或不支持按行列插入时,追加到末尾。
            try
                doc.appendText(code);
                ok = true;
            catch
                ok = false;
            end
        end
    end
end
