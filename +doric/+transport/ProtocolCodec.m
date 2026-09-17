classdef ProtocolCodec
%PROTOCOLCODEC Encode requests and decode lines of the doric_bridge line protocol.
%
%   line = doric.transport.ProtocolCodec.encodeRequest(id, command, args)
%       args is a struct of scalar numeric/logical/char values (no spaces). Two fields are
%       special: Settings (doric.ChannelSettings, expanded to SETTINGS keys) and Positional
%       (cellstr appended as bare tokens, e.g. for SIMFAIL).
%   tokens = doric.transport.ProtocolCodec.settingsTokens(settings)
%       The SETTINGS keys for a doric.ChannelSettings (without port/ch).
%   msg = doric.transport.ProtocolCodec.decodeLine(line, time)
%       Message struct (see doric.transport.Transport) for one bridge output line. Lines not
%       starting with "@D " are library output (Kind 'libmsg', Source 'raw').
%   text = doric.transport.ProtocolCodec.decodeValue(text)
%       Undo the bridge's %XX encoding.
%
%   Errors
%       doric:ProtocolCodec:invalidArgument  a value contains whitespace or is not scalar
%
%   See also docs/bridge-protocol.md, doric.transport.BridgeTransport

    methods (Static)
        function line = encodeRequest(id, command, args)
            parts = {sprintf('%d', id), upper(char(command))};
            if nargin >= 3 && ~isempty(args)
                names = fieldnames(args);
                for k = 1:numel(names)
                    name = names{k};
                    value = args.(name);
                    switch name
                        case 'Settings'
                            parts = [parts, doric.transport.ProtocolCodec.settingsTokens(value)]; %#ok<AGROW>
                        case 'Positional'
                            parts = [parts, cellstr(value)]; %#ok<AGROW>
                        otherwise
                            parts{end + 1} = [name '=' ...
                                doric.transport.ProtocolCodec.formatValue(name, value)]; %#ok<AGROW>
                    end
                end
            end
            line = strjoin(parts, ' ');
        end

        function tokens = settingsTokens(s)
            if ~isa(s, 'doric.ChannelSettings') || ~isscalar(s)
                error('doric:ProtocolCodec:invalidArgument', ...
                    'Settings must be a scalar doric.ChannelSettings.');
            end
            tokens = { ...
                sprintf('mode=%d', int32(s.Mode)), ...
                sprintf('ttlout=%d', s.IsTTLOutput), ...
                sprintf('trigtype=%d', int32(s.TriggerType)), ...
                sprintf('trigmode=%d', int32(s.TriggerMode)), ...
                sprintf('repeat=%d', s.IsRepeatableSequence), ...
                sprintf('curmode=%d', int32(s.CurrentMode)), ...
                sprintf('ttl.current=%d', s.CurrentmA), ...
                sprintf('ttl.startdelay=%d', s.StartingDelayMs), ...
                sprintf('ttl.seqdelay=%d', s.DelayBetweenSeqMs), ...
                sprintf('ttl.period=%.17g', s.PeriodMs), ...
                sprintf('ttl.on=%.17g', s.TimeOnMs), ...
                sprintf('ttl.rise=%d', s.RisingTimeMs), ...
                sprintf('ttl.fall=%d', s.FallingTimeMs), ...
                sprintf('ttl.nseq=%d', s.NbOfSeq), ...
                sprintf('ttl.npulses=%d', s.NbOfPulsesPerSeq), ...
                sprintf('ncx=%d', numel(s.ComplexSegments))};
            for k = 1:numel(s.ComplexSegments)
                c = s.ComplexSegments(k);
                p = sprintf('cx%d.', k - 1);
                tokens = [tokens, { ...
                    sprintf('%smode=%d', p, int32(c.Mode)), ...
                    sprintf('%scurrent=%d', p, c.CurrentmA), ...
                    sprintf('%sseqdelay=%d', p, c.DelayBetweenSeqMs), ...
                    sprintf('%speriod=%.17g', p, c.PeriodMs), ...
                    sprintf('%son=%.17g', p, c.TimeOnMs), ...
                    sprintf('%snseq=%d', p, c.NbOfSeq), ...
                    sprintf('%snpulses=%d', p, c.NbOfPulsesPerSeq), ...
                    sprintf('%sstartdelay=%d', p, c.StartingDelayMs)}]; %#ok<AGROW>
            end
            points = s.CustomDataPoints;
            last = find(points ~= 0, 1, 'last');
            if ~isempty(last)
                % Trailing zeros are implicit: the bridge zero-fills the 1000-point array.
                tokens{end + 1} = ['custom=' strjoin(arrayfun(@(v) sprintf('%d', v), ...
                    points(1:last), 'UniformOutput', false), ',')];
            end
        end

        function msg = decodeLine(line, time)
            if nargin < 2, time = 0; end
            line = char(line);
            if ~startsWith(line, '@D ')
                msg = doric.transport.Transport.newMessage('libmsg');
                msg.Source = 'raw';
                msg.Text = strtrim(line);
                msg.Severity = doric.transport.MessageClassifier.classify(msg.Text);
                msg.Time = time;
                return
            end
            rest = line(4:end);
            [first, rest] = strtok(rest, ' ');
            if strcmp(first, 'EVT')
                [name, rest] = strtok(rest, ' ');
                data = doric.transport.ProtocolCodec.parseKeyValues(rest);
                if strcmp(name, 'LIBMSG')
                    msg = doric.transport.Transport.newMessage('libmsg');
                    msg.Id = str2double(doric.transport.ProtocolCodec.field(data, 'id', '0'));
                    msg.Source = doric.transport.ProtocolCodec.field(data, 'src', '');
                    msg.Text = doric.transport.ProtocolCodec.field(data, 'text', '');
                    msg.Severity = doric.transport.ProtocolCodec.field(data, 'sev', '');
                    if isempty(msg.Severity)
                        msg.Severity = doric.transport.MessageClassifier.classify(msg.Text);
                    end
                else
                    msg = doric.transport.Transport.newMessage('event');
                    msg.Name = name;
                    msg.Text = doric.transport.ProtocolCodec.field(data, 'text', '');
                    msg.Code = doric.transport.ProtocolCodec.field(data, 'code', '');
                end
                msg.Data = data;
            else
                msg = doric.transport.Transport.newMessage('reply');
                msg.Id = str2double(first);
                [status, rest] = strtok(rest, ' ');
                if strcmp(status, 'OK')
                    msg.Ok = true;
                    msg.Data = doric.transport.ProtocolCodec.parseKeyValues(rest);
                else
                    msg.Ok = false;
                    [msg.Code, rest] = strtok(rest, ' ');
                    msg.Text = strtrim(rest);
                    if ~strcmp(status, 'ERR')
                        msg.Code = 'protocolError';
                        msg.Text = strtrim(line);
                    end
                end
            end
            msg.Time = time;
        end

        function text = decodeValue(text)
            text = char(text);
            if ~contains(text, '%')
                return
            end
            bytes = uint8(text);
            out = zeros(1, numel(bytes), 'uint8');
            n = 0;
            k = 1;
            while k <= numel(bytes)
                if bytes(k) == uint8('%') && k + 2 <= numel(bytes)
                    code = sscanf(char(bytes(k + 1:k + 2)), '%2x');
                    if ~isempty(code)
                        n = n + 1;
                        out(n) = code;
                        k = k + 3;
                        continue
                    end
                end
                n = n + 1;
                out(n) = bytes(k);
                k = k + 1;
            end
            text = native2unicode(out(1:n), 'UTF-8');
        end
    end

    methods (Static, Access = private)
        function text = formatValue(name, value)
            if islogical(value)
                value = double(value);
            end
            if isnumeric(value) && isscalar(value) && isreal(value)
                if value == fix(value)
                    text = sprintf('%d', value);
                else
                    text = sprintf('%.17g', value);
                end
            elseif ischar(value) || (isstring(value) && isscalar(value))
                text = char(value);
                if isempty(text) || any(isspace(text))
                    error('doric:ProtocolCodec:invalidArgument', ...
                        'Value of %s must be non-empty text without spaces.', name);
                end
            else
                error('doric:ProtocolCodec:invalidArgument', ...
                    'Value of %s must be a real scalar or text.', name);
            end
        end

        function data = parseKeyValues(text)
            data = struct();
            tokens = strsplit(strtrim(text), ' ');
            for k = 1:numel(tokens)
                token = tokens{k};
                eq = find(token == '=', 1);
                if isempty(eq) || eq == 1
                    continue
                end
                key = matlab.lang.makeValidName(token(1:eq - 1), 'ReplacementStyle', 'underscore');
                data.(key) = doric.transport.ProtocolCodec.decodeValue(token(eq + 1:end));
            end
        end

        function value = field(data, name, default)
            if isfield(data, name)
                value = data.(name);
            else
                value = default;
            end
        end
    end
end
