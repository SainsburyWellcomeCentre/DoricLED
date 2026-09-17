function varargout = app(varargin)
%APP Open the light-source control window.
%
%   doric.app()              opens a window that owns its own doric.LightSource (real device)
%   doric.app(lightSource)   attaches to an existing doric.LightSource (never disconnects it)
%   doric.app(..., 'Name', value)  options of doric.gui.LightSourceApp
%   a = doric.app(...)       returns the doric.gui.LightSourceApp object
%
%   See also doric.gui.LightSourceApp, doric.LightSource

    appObject = doric.gui.LightSourceApp(varargin{:});
    if nargout > 0
        varargout{1} = appObject;
    end
end
