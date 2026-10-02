function cfg = config_params()
%CONFIG_PARAMS  All tunable parameters for the SMART-EVP simulation.
%   Units: seconds, metres, vehicles. Change values here only.

% ---- Simulation ----
cfg.dt      = 0.5;      % time step [s]
cfg.simTime = 240;      % simulated horizon [s]

% ---- Corridor geometry (ambulance starts at x = 0 on road "A") ----
cfg.nJunctions    = 3;
cfg.firstJunction = 300;                 % m from start to first stop line
cfg.spacing       = 400;                 % m between junctions
cfg.junctionPos   = cfg.firstJunction + (0:cfg.nJunctions-1)*cfg.spacing;
cfg.exitMargin    = 15;                  % exit sensor sits this far past the stop line [m]
cfg.endPos        = cfg.junctionPos(end) + 200;   % hospital gate

% ---- Signal timing (two phases: A = ambulance road, B = cross road) ----
cfg.greenA = 30;  cfg.greenB = 25;
cfg.yellow = 4;   cfg.allRed = 2;
cfg.minGreen = 10;                       % minimum green before a phase may be cut short
cfg.startupLost = 2;                     % start-up lost time at each green [s]
cfg.satFlow = 0.5;                       % saturation flow [veh/s] (1800 veh/h)
cfg.maxRecoveryGreen = 35;               % cap on the recovery green for road B [s]
cfg.recoveryQ = 2;                       % junction "recovered" when total queue <= this [veh]
cfg.cycle = cfg.greenA + cfg.greenB + 2*(cfg.yellow + cfg.allRed);

% ---- Normal traffic ----
cfg.lambdaA = 0.12;                      % arrivals road A [veh/s]
cfg.lambdaB = 0.12;                      % arrivals road B [veh/s]
cfg.vehLen  = 7.5;                       % queue length per vehicle [m]

% ---- Ambulance ----
cfg.vAmb   = 16.7;                       % cruising speed [m/s] (~60 km/h)
cfg.accel  = 2.5;                        % [m/s^2]
cfg.decel  = 3.0;                        % planned braking [m/s^2]
cfg.decelMax = 6.0;                      % hardest allowed braking [m/s^2]
cfg.vQueue = 5;                          % speed when filtering through a discharging queue [m/s]
cfg.bypassFactor = 0.3;                  % fraction of queue length the ambulance cannot bypass

% ---- Communication / EVP logic ----
cfg.msgPeriod      = 1;                  % ambulance message period [s]
cfg.rangeLocal     = 250;                % local radio range [m]
cfg.rangeCorridor  = 1000;               % pre-notification range with corridor coordination [m]
cfg.pLoss          = 0.05;               % packet loss probability
cfg.leadTime       = 20;                 % start preemption when ETA <= this [s]
cfg.dropoutTimeout = 3;                  % release preemption if no valid message for this long [s]
cfg.maxPreempt     = 60;                 % watchdog: max continuous preemption [s]
cfg.maxMsgAge      = 2;                  % reject messages older than this [s]
cfg.minEtaSpeed    = 5;                  % speed floor used in ETA calculation [m/s]
cfg.adaptiveMargin = 5;                  % safety margin for the adaptive (just-in-time) trigger [s]

% ---- Security (DEMO KEYS - never commit real keys, never export them) ----
cfg.ambId = 'AMB-001';
cfg.keys  = containers.Map({'AMB-001','AMB-002'}, ...
                           {'demo-key-amb001-change-me','demo-key-amb002-change-me'});
cfg.attackerKey = 'attacker-guess';

% ---- Two-ambulance scenario: AMB-001 carries a patient, AMB-002 is empty ----
cfg.prio = containers.Map({'AMB-001','AMB-002'}, {2, 1});   % 2 = patient on board, 1 = empty
cfg.emptyGetsPriority = true;   % false => an empty ambulance is treated as ordinary traffic
cfg.commitDist = 50;            % an ambulance this close to the stop line keeps its green (m)
cfg.bStopPos   = 300;           % stop-line position along a cross road (empty ambulance frame)
cfg.amb2 = struct( ...
    'mode',        'cross', ... % 'cross' = empty ambulance uses cross road B, 'follow' = same road as patient
    'junction',    2, ...       % junction crossed by the empty ambulance in 'cross' mode
    'startTime',   22, ...      % departure time in 'cross' mode [s] (22 s => arrives with the patient)
    'followDelay', 30);         % seconds behind the patient in 'follow' mode
end
