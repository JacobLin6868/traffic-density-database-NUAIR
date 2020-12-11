classdef TrafficDensity
% Copyright 2019 - 2020, MIT Lincoln Laboratory
% SPDX-License-Identifier: X11
%
% TRAFFICDENSITY class: load and compute aircraft traffic density
%   Class that loads and computes aircraft traffic density and
%   estimates the midair collision rate
    
    % Constant properties
    properties (Constant = true , Access = private)
        % Unit conversions
        g = 32.2;                 % g = gravity = 32.2 ft/s/s
        kt2ftps = 1.68780986;     % Convert from knots -> ft/sec
        deg2rad = pi/180;         % Convert from degrees -> radians
        sec2min = 1/60;           % Convert from seconds -> minutes
        ft2nm = 0.000164578834;   % Convert from ft -> nm
        f2m = 3.28084;            % Convert from meters -> ft [Note: this is backwards the convention of other constants]
        hr2s = 3600;              % Convert from hr -> s
        
        % Other constants
        earthellipsoid = almanac('earth','ellipsoid','nm');
    end
    
    % Internal hidden properties (for internal processing)
    properties (Access = private)
        uncor               % Uncorrelated encounter model properties
        cor                 % Correlated encounter model properties        
        states              % Internal mapping data for states
    end
    
    % Data that can be accessed but not modified
    properties (SetAccess = private)
        cell                % Density table data (read-only)
        jobdata             % Density meta-information (read-only)
        cellcoverage        % Surveillance (radar) coverage fraction for each cell (read-only)
        airport             % Airport information for plotting (read-only)
        airspace            % Airspace class information (read-only)
        cellAirspace        % Airspace class fraction for each cell, generated by Utilities/getCellAirspace.m (read-only)
        termaplegend        % Matlab mapping reference (read-only)
        validinds logical   % Indices into cell that satisfy user input parameters (read-only)
        obshrs              % Number of observed hours (reduced as necessary based on user selection) (read-only)
        globe               % Terrain elevation data [m] (read-only)
        el                  % Terrain elevation [ft] (read-only)
        density             % Resulting density data [AC/NM^3] (read-only)
        rate                % Resulting collision rate [AC/hr] (read-only)
        count               % Resulting count data ([AC] for max occupancy, [AC hrs] for others) (read-only)
        summarize           % Resulting data if summarizing area (read-only)
        airspaceClass       % Resulting airspace class (read-only)
        cellLatMidpoints    % Latitude midpoints for each cell [deg] (read-only)
        cellLonMidpoints    % Longitude midpoints for each cell [deg] (read-only)
        cellLatCutpoints    % Latitude cutpoints/bounds for each cell [deg] (read-only)
        cellLonCutpoints    % Longitude cutpoints/bounds for each cell [deg] (read-only)
        cellLims            % Latitude/longtiude cells processed based on input specified by user (read-only)
        latlim              % Internal latitude limit based on input specified by user (read-only)
        lonlim              % Internal longitude limit based on input specified by user (read-only)
        cellLatLim          % Latitude matrix indices corresponding to latlim (read-only)
        cellLonLim          % Longitude matrix indices corresponding to lonlim (read-only)
        relSpeed            % Relative speed between input track and intruder, output for testing purposes [kts] (read-only)
    end

    % Public properties that can be set by user  
    properties 
        % Structure with filenames for data to be loaded
        filenames = struct('cell','cell.mat',...
            'job','job.dat',...
            'cellCoverage','cellcoverage.mat',...
            'uncorEncModel','uncor_v2p1.txt',...
            'corEncModel','cor_v2p1.txt',...
            'airport','APT.mat',...
            'airspace','airspace-B-C-D-24-Oct-2019.mat',...
            'cellAirspace','cellAirspace.mat');      
        
        % Limited area to be processed, specified by Latitude/Longitude structure field limits
        area = struct('LatitudeLimit',[23,50],'LongitudeLimit',[-127,-65]); % Default is approximate contiguous US area
        
        % Specific track to be processed, if specified will process by track rather than area
        track = struct('Time_s',[],'Latitude_deg',[],'Longitude_deg',[],'Altitude_MSL_ft',[],'Speed_kts',[]);
        processtrack(1,1) logical {mustBeNumericOrLogical} = false; % Whether to process track, rather than area (boolean)
        
        % Time of day, month, day of week specification
        timeofday(1,:) {mustBeInteger,mustBeLessThanOrEqual(timeofday,7),mustBeGreaterThanOrEqual(timeofday,0)} = 0:7; % UTC time of day (3 hour time period, 0 based index - integer from 0-7), default is to process all
        monthofyear(1,:) {mustBeInteger,mustBeLessThanOrEqual(monthofyear,12),mustBeGreaterThanOrEqual(monthofyear,1)} = 1:12; % Month of year (integer from 1-12), default is to process all 
        dayofweek(1,:) {mustBeInteger,mustBeLessThanOrEqual(dayofweek,7),mustBeGreaterThanOrEqual(dayofweek,1)} = 1:7; % Day of week (integer from 1 (Sunday) to 7 (Saturday)), default is to process all        
    
        ACcategory (1,:) {mustBeInteger,mustBeLessThanOrEqual(ACcategory,1),mustBeGreaterThanOrEqual(ACcategory,0)} = [0 1]; % Aircraft type (1: 1200-code or 0: discrete) [not specified = both]
        processNoncoop (1,1) logical {mustBeNumericOrLogical} = false; % Whether to process noncooperative estimates from 1200-code data (only used by plot method) (true = yes) 
        noncoopFactor (1,1) {mustBeGreaterThanOrEqual(noncoopFactor,0)} = 0.23; % Relative fraction of noncooperative to 1200-code density 
        
        % Altitude/height (cooresponding to altitude bins in jobdata), 0 based indexing
        height(1,:) {mustBeInteger,mustBeGreaterThanOrEqual(height,0)}
        
        % Whether to plot results (true = yes)
        plotresults(1,1) logical {mustBeNumericOrLogical} = true; 
        plotAirport(1,1) logical {mustBeNumericOrLogical} = true; % Whether to plot airports (true = yes)
        plotMaxNAirport(1,1) {mustBeInteger} = 50; % Maximum number of airports to plot
        
        % Own aircraft speed [kts]
        % If undefined will use average from encounter model, or if track
        % defined, will use track speed and ignore this parameter [kts]
        % Can be a scalar, or must be equal to the number of altitude bins
        % in density data (as specified in jobdata.GRID_H_NUM)
        ownspeed(1,:) {mustBePositive,mustBeLessThanOrEqual(ownspeed,1200)};   
    
        % Collision cylinder size: default is RQ-4A with King Air 
        macR(1,1) {mustBePositive,mustBeGreaterThanOrEqual(macR,0)} = 83.2; % Collision cylinder radius (sum of the half wing spans for the two aircraft) [ft]
        macH(1,1) {mustBePositive,mustBeGreaterThanOrEqual(macH,0)} = 14.4; % Collision cylinder height (sum of the half height for the two aircraft) [ft]

        % Whether to correct for cell coverage (true=yes), by inflating the density/collision rate
        correctcoverage(1,1) logical {mustBeNumericOrLogical} = true;
        noCoverageThreshold(1,1) {mustBeNumeric,mustBeLessThanOrEqual(noCoverageThreshold,1),mustBeGreaterThanOrEqual(noCoverageThreshold,0)} = 0.2; % Radar coverage threshold for declaring insufficient coverage in a cell (set to 0 to get all data)
        
        % Whether to get upper bound of confidence interval (automatically
        % set to false if the statistics toolbox does not exist)
        computeub(1,1) logical {mustBeNumericOrLogical} = true; 
        
        % Whether to compute maximum density (automatically set to false if mex
        % (compiled) function accumarraymax_mex does not exist
        computemax(1,1) logical {mustBeNumericOrLogical} = true; 
        
        % Whether to compute standard deviation (true=yes), which requires significant time to compute
        computestd(1,1) logical {mustBeNumericOrLogical} = false;  
        
        % Whether should output clarifying text (verbose mode) (true=yes)
        verbose(1,1) logical {mustBeNumericOrLogical} = true;
        
        cialpha(1,1) {mustBeNumeric,mustBeLessThanOrEqual(cialpha,1),mustBeGreaterThanOrEqual(cialpha,0)} = 0.05; % Alpha parameter for confidence interval computation
        ciIndObsPerHr(1,1) {mustBeNumeric,mustBeGreaterThan(ciIndObsPerHr,0)} = 10; % Assumed number of independent observations per hour (6 minutes roughly corresponds to time for GA aircraft to traverse 10 NM)
    end
    
    %% Protected methods (access only in class or subclasses)
    % Methods are primarily protected to prevent unintended execution
    % (e.g., out of order)
    methods(Access = protected)
        % Function declarations for methods in separate files
        obj = runTrack(obj);             % Evaluate risk given track (executed from generic run method as appropriate)
        obj = runArea(obj);              % Evaluate risk given area (executed from generic run method as appropriate)
        obj = getTrafficDensity(obj);    % Get traffic density for given region        
        obj = loadEncModel(obj);         % Get encounter model information
        obj = getValidInds(obj);         % Get valid indices into density data
             
        % Inline functions 
        function obj = loadJobData(obj)
            % Load data from input jobfile
            if ~exist(obj.filenames.job,'file')
                error('Job characterization file does not exist on Matlab path');
            end
            job = readtable(obj.filenames.job,'ReadVariableNames',false,'Format','%s%s');
            job.Properties.VariableNames = {'Name','Value'};
            for rr = 1:size(job,1)
                fname = table2cell(job(rr,1));
                fvalue = table2cell(job(rr,2));
                obj.jobdata.(fname{1}) = str2num(fvalue{1}); %#ok<ST2NM>
            end
            obj.termaplegend = [ obj.jobdata.BINS_PER_DEGREE obj.jobdata.NORTH_LAT obj.jobdata.WEST_LON];
            obj.jobdata.GRID_H_NUM = length(obj.jobdata.AGL_LIMS)+length(obj.jobdata.MSL_LIMS)-1;
                        
            % Cutpoints of input data cell
            obj.cellLatCutpoints = fliplr(obj.termaplegend(2):-1/obj.termaplegend(1):obj.termaplegend(2)-obj.jobdata.GRID_Y_NUM/obj.termaplegend(1));
            obj.cellLonCutpoints = obj.termaplegend(3):1/obj.termaplegend(1):obj.termaplegend(3)+obj.jobdata.GRID_X_NUM/obj.termaplegend(1);     
            
        end
    end
    
    %% Public methods
    methods
        %% Constructor
        function obj = TrafficDensity(jobfile)
            %TRAFFICDENSITY constructor: Construct an instance of the TrafficDensity class   
            % Can specify optional jobdata file as input
            
            if exist('jobfile','var')
                if ~ischar(jobfile)
                    error('jobdata file input to constructor must be a character');
                end
                obj.filenames.job = jobfile;
            end            
            % Load job information here so that can correct input errors
            obj = obj.loadJobData;      
            
            % Check whether all tool dependencies are installed. If not,
            % turn optional computations off.
            obj = obj.checkDependencies;
            
        end
        
        %% Function to Check Dependencies
        function obj = checkDependencies(obj)
            %Set computeub to false, if statistics_toolbox is not on user's
            %path
            if ~license('test','statistics_toolbox')
                obj.computeub = false;
            end
            
            %Set computemax to false, if mex (compiled) function
            %accumarraymax_mex does not exist
            if ~exist('accumarraymax_mex','file')
                obj.computemax = false;
            end
            
        end
        
        %% Property setters         
        % Error checking for area structure 
        function obj = set.area(obj,value) 
            assert(isstruct(value),'area property must be structure with 1x2 parameters LatitudeLimit and LongitudeLimit');
            assert(isempty(setxor(fieldnames(value),fieldnames(obj.area))),'Only LatitudeLimit and LongitudeLimit can be specified as fields');
            assert(all(size(value.LatitudeLimit)==[1,2]) && all(size(value.LongitudeLimit)==[1,2]),...
                'Size of LatitudeLimit and LongitudeLimit must be 1x2');
            assert(value.LatitudeLimit(1)<=value.LatitudeLimit(2) & value.LongitudeLimit(1)<=value.LongitudeLimit(2),...
                'Order of LatitudeLimits and LongitudeLimits must be (min, then max)');
            % Changing latitude limit
            if any(value.LatitudeLimit~=obj.area.LatitudeLimit)
                errorMsgLat = sprintf('LatitudeLimits are out of bounds. Min latitude is %f.2 and max latitude is %f.2', min(obj.cellLatCutpoints), max(obj.cellLatCutpoints));
                assert(value.LatitudeLimit(1)>=min(obj.cellLatCutpoints) & value.LatitudeLimit(2)<=max(obj.cellLatCutpoints),errorMsgLat);
            end
            % Changing longitude limit
            if any(value.LongitudeLimit~=obj.area.LongitudeLimit)
                errorMsgLon = sprintf('LongitudeLimits are out of bounds. Min longitude is %f.2 and max longitude is %f.2', min(obj.cellLonCutpoints), max(obj.cellLonCutpoints));
                assert(value.LongitudeLimit(1)>=min(obj.cellLonCutpoints) & value.LongitudeLimit(2)<=max(obj.cellLonCutpoints),errorMsgLon);
            end
            obj.area = value;
            obj.processtrack = false; %#ok<*MCSUP>
            obj.rate = []; obj.density = []; obj.count = []; obj.summarize = []; % Reset output data
        end
        
        % Error checking for track structure
        function obj = set.track(obj,value)
            assert(isstruct(value),'track property must be structure with 1x2 parameters LatitudeLimit and LongitudeLimit');
            assert(isempty(setxor(fieldnames(value),fieldnames(obj.track))),'Only Time_s, Latitude_deg, Longitude_deg, Altitude_MSL_ft, and Speed_kts can be specified as fields');
            assert(all(diff(value.Time_s)>0),'Track time must be monotonically increasing')
            assert(all(value.Speed_kts>=0),'Track speed must be positive')
            if(any(value.Altitude_MSL_ft<-2000)); warning('Track altitude detected less than -2000 ft MSL: verify that this is correct'); end
            obj.track = value;
            obj.processtrack = true; %#ok<*MCSUP>
            obj.rate = []; obj.density = []; obj.count = []; obj.summarize = []; % Reset output data
        end        
       
        function obj = set.timeofday(obj,value)
            % Additional time of day input error checking (based on job information)
            assert(all(value<=obj.jobdata.GRID_T_NUM-1),'Error setting property ''timeofday'': must be less than %i',obj.jobdata.GRID_T_NUM-1)
            obj.timeofday = value;
        end
        
        function obj = set.height(obj,value)
            % Additional height input error checking (based on job information)
            assert(all(value<=obj.jobdata.GRID_H_NUM-1),'Error setting property ''height'': must be less than %i',obj.jobdata.GRID_H_NUM-1)
            obj.height = value;
        end        
        
        function obj = set.processNoncoop(obj,value)
            % If process noncooperative, make sure that also processing
            % 1200-code
            assert(~value | any(obj.ACcategory==1) | isempty(obj.ACcategory),'Must process 1200-code with noncooperatives (ACcategory must include 1)');
            obj.processNoncoop = value;
        end
        
        function obj = set.computeub(obj,value)
            if license('test','statistics_toolbox')
                obj.computeub = value;
            else %statistics toolbox does not exist
                if value == true
                    warning('Matlab statistics toolbox is required to compute upper bound of confidence interval. Not setting computeub to true.');
                end
            end
        end
        
        function obj = set.computemax(obj,value)
            if exist('accumarraymax_mex','file')
                obj.computemax = value;
            else %accumarraymax_mex function does not exist
                if value == true
                    warning('accumarraymax_mex function is required to compute maximum density. Not setting computemax to true.');
                end
            end
        end
        
        function obj = set.computestd(obj,value)
            obj.computestd = value;
        end
        
        function obj = set.filenames(obj,value)
            % Error checking for filename setting
            assert(isstruct(value),'filenames property must be structure');
            correctFilenameFields = fieldnames(obj.filenames);
            filenameFieldsStr = [];
            for ff = 1:length(correctFilenameFields)
                filenameFieldsStr = [filenameFieldsStr,correctFilenameFields{ff},', ']; %#ok<AGROW>
            end
            filenameFieldsStr = filenameFieldsStr(1:end-2);
            assert(isempty(setxor(fieldnames(value),fieldnames(obj.filenames))),['filenames structure must only include filenames: ',filenameFieldsStr]); 
            valuefieldnames = fieldnames(value);
            for vv = 1:length(valuefieldnames) % Check each value in the structure
                currfield = valuefieldnames{vv};
                currvalue = value.(currfield);
                if ~ischar(currvalue); error('%s field in filenames property must be a character string',currfield); end
                if ~exist(currvalue,'file'); error('%s file does not exist on Matlab path',currvalue); end
            end          
            
            % Load job information again so that can correct input errors
            obj = obj.loadJobData;
            
            if obj.verbose; disp('Because input data files modified, returning properties to default'); end            
            mc = ?TrafficDensity; % Class meta data
            mp = mc.PropertyList; % Property structure
            for pp = 1:length(mp)
                if strcmp(mp(pp).Name,'filenames') % Do not reset filenames
                    continue;
                end
                if strcmp(mp(pp).SetAccess,'public')
                    if mp(pp).HasDefault 
                        obj.(mp(pp).Name) = mp(pp).DefaultValue;                        
                    else
                        obj.(mp(pp).Name) = [];
                    end
                end
            end            

            obj.cell = []; % Clear cell to force reload of data
            
            obj.filenames = value;            
        end

        %% Functions
        % Function declarations for methods in separate files
        obj = SummarizeData(obj); % Quickly summarize loaded data
        obj = LoadData(obj);      % Load input data
        [data,summarize] = plot(obj,varargin); % Plot results on a map

        % Inline functions 
        function obj = run(obj)
            % User initiated function to process density data 
            % Will evaluate track or geographic area based on user
            % specified input
            if isempty(obj.cell)
                warning('Must load data before processing; loading now');
                obj = obj.LoadData;
            end

            obj = obj.getValidInds; % Get indices into cell based on input limitations
            obj = obj.getTrafficDensity; % Get the traffic density
            if obj.processtrack % Process track or area as required
                obj = obj.runTrack;
            else
                obj = obj.runArea;
            end 
        end 
        
        % Get the memory size of the object
        function GetSize(obj)
            props = properties(obj);
            totSize = 0;
            
            for ii=1:length(props)
                currentProperty = obj.(char(props(ii))); %#ok<NASGU>
                s = whos('currentProperty');
                totSize = totSize + s.bytes;
            end
            
            fprintf(1, 'Approximate object memory size: %.3g GB\n', totSize/1024^3);
        end        
    end
end

