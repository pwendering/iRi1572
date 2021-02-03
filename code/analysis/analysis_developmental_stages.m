% determine important carbon sources under different developmental stages
% upper bounds for reactions are limited by v_max which is estimated from
% transcript abundances and k_cat values
% initCobraToolbox(false);
changeCobraSolver('ibm_cplex', 'all');
disp('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~')
disp('|                       START                        |')
disp('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~')
disp('')
try
    parpool(3);
catch
    disp('Parallel pool already available')
end

topDir = '';

% new sampling or only analysis of results
new = false;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Input data
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% ~~~~~~~~~~~~~~~~~ carbon sources ~~~~~~~~~~~~~~~~~ %
carbonSources = {
    'm0564[e0]' % Glucose
    'm0588[e0]' % Fructose
    'm0047[e0]' % Raffinose
    'm1282[e0]' % Melibiose
    };

monosaccharideImportRxns = {'r0822_e0_f', 'r0824_e0_f', 'r1531_e0_f'};
concentration = 1000;

% ~~~~~~~~~~~~~~~~~~~~~~ model ~~~~~~~~~~~~~~~~~~~~~~ %
modelFile = fullfile(topDir,'model/iRi1572.mat');

% uptake reactions to be removed
oldUptake = {
    'r1533_e0' % D-Glucose
    'r1534_e0' % D-Fructose
    'r1006_e0' % myo-Inositol
    'r1002_e0' % Glycine
    'r1633_e0' % Myristate
    };

% ~~~~~~~~~~~~~~ transcriptomics data ~~~~~~~~~~~~~~~ %
transcriptomicDir = fullfile(topDir, 'data/transcriptomic-data';
transcriptomicFiles = {...
    fullfile(transcriptomicDir, 'transcriptomic_ERM.csv'),...
    fullfile(transcriptomicDir, 'transcriptomic_HYP.csv'),...
    fullfile(transcriptomicDir, 'transcriptomic_ARB.csv'),...
    };
nStages = numel(transcriptomicFiles);
experiments = regexp(transcriptomicFiles,'(ARB)|(ERM)|(HYP)', 'match');
experiments = [experiments{:}];
clear transcriptomicDir

% ~~~~~~~~~~~~~~~~~~~~~~ kcats ~~~~~~~~~~~~~~~~~~~~~~ %
maxKcatFile = fullfile(topDir, 'kcats/kcat-reference-data.tsv');
modelKcatsFile = fullfile(topDir, 'kcats/kcats_model.txt');

% ~~~~~~~~~~~~~~~~~~ UniProt data ~~~~~~~~~~~~~~~~~~~ %
uniProtFile = fullfile(topDir, 'uniprot.tab');

% ~~~~~~~~~~~~~~~~ output directory ~~~~~~~~~~~~~~~~~ %
outDir = fullfile(topDir, '/results/developmental-stages/');

% ~~~~~~~~~~~~~~~~ experimental data ~~~~~~~~~~~~~~~~ %
% set total protein content (maximum over all conditions [Hildebrand et al.
C = 0.106;
C = 1.2*C; % as in the estimation of protein concentrations
C_sd = 3.5*1E-3; % sd for max protein content;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Input processing
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% ~~~~~~~~~~~~~~~~~~~~~~ model ~~~~~~~~~~~~~~~~~~~~~~ %
fprintf('\nPreparing the model\n')
% load the model file
load(modelFile)

% limit palmitate uptake to the minimum flux at optimal growth using
% standard FBA
palmitateIdx = findRxnIDs(model,'r1007_e0');
tmpModel = model;
% limit biomass reaction to optimal growth rate
s = optimizeCbModel(tmpModel);
tmpModel.lb(model.c==1) = s.f;
% change objective to minimization of palmitate uptake
tmpModel.c(:) = 0;
tmpModel.c(palmitateIdx) = 1;
tmpModel.osenseStr = 'min';
s = optimizeCbModel(tmpModel);
% set palmitate uptake to the minimum possible flux at optimal growth
model.lb(palmitateIdx) = s.f;
clear tmpModel s palmitateIdx

% remove blocked reactions
% add additional carbon sources temporarily to reactions acting on it are not blocked
model = addReaction(model, 'tmpRxn', 'reactionFormula', ['-> ' strjoin(carbonSources,' + ')],...
    'printLevel', 0);
blockedReactions = findBlockedReaction(model);
model = removeRxns(model, blockedReactions, 'metFlag', false);
model = removeRxns(model, 'tmpRxn', 'metFlag', false);

% split reversible reactions
model = convertToIrreversible(model);

% remove genes which are not used in any reaction
model = removeUnusedGenes(model);
model = rmfield(model,'rxnGeneMat');

% ~~~~~~~~~~~~~~~~~~~~~~ kcats ~~~~~~~~~~~~~~~~~~~~~~ %
fprintf('\n> associating kcats to reactions\n')

% assign reaction-specific kcats from EC numbers associated to the
% reactions; read from modelKcatsFile if already done before
kcats = assign_kcats(model, maxKcatFile, 'fungi', modelKcatsFile);

% assign the median kcat of non-zero values to all reactions with unknown
% kcat; lower of equal to zero because some values are negative as obtained
% from BRENDA
kcats(kcats<=0) = median(kcats(kcats>0));

% multiply with 3600 to obtain [h^-1] as unit
kcats = kcats * 3600;

% remove previously uptake reactions for carbon sources
idxRemove = contains(model.rxns, oldUptake);
model = removeRxns(model, model.rxns(idxRemove));

% remove kcats of removed reactions
kcats(idxRemove) = [];
clear idxRemove

% ~~~~~~~~~~~~~~ add uptake reactions ~~~~~~~~~~~~~~~ %
% add uptake reactions for all carbon sources
fprintf('> adding uptake reactions\n')
uptakeRxns = repmat({''}, numel(carbonSources),1);
cSourceNames = repmat({''}, numel(carbonSources),1);
nRxns = numel(model.rxns);
for i=1:numel(carbonSources)
    cSourceNames{i} = model.metNames{findMetIDs(model, carbonSources(i))};
    uptakeRxns{i} = ['r',num2str(nRxns+1),'_e0'];
    
    model = addReaction(model, uptakeRxns{i},...
        'reactionName', [cSourceNames{i}, '_uptake'],...
        'reactionFormula', ['-> ', carbonSources{i}],...
        'upperBound', concentration);
    nRxns = numel(model.rxns);
    
end
clear metName oldUptake
model.subSystems(end-3:end) = {{'Medium'}};
uptakeIdx = findRxnIDs(model, uptakeRxns);

% limit the transport/influx reactions for the respective carbon
% sources depending of the concentrations (hexose transporter kinetics
% were taken from S. cerevisiae as not all values were available for R. irregularis)
% > use high affinity transport kinetics
% > use lowest Km and highest Vmax measured to avoid
%   overconstraining the model (+/- standard deviation,
%   respectively)
% sources: Reifenberger et al. 1997, European Journal of Biochemistry, 245: 324-333
%          Meijer et al. 1996, Biochimica et Biophysica Acta (BBA) - Bioenergetics, 1277(3), 209-216
%               Km (mM)              Vmax (nmol min^-1 mg^-1)
% glucose:        0.7                       173
% fructose:       8.7                       15.6 * (1000 / 60) = 260
% galactose:      0.8                       139
% v = (Vmax * [S]) / (Km + [S])
% concentrations are given in [mM]
vMaxFactor = 60 / 1000;

% find transport reaction indices for carbon sources or the respective
% monosaccharides, which can be imported (forward direction)
transRxnIdx = ismember(model.rxns, monosaccharideImportRxns);
if sum(transRxnIdx)~=numel(monosaccharideImportRxns)
    error('at least one import reaction ID was not found in the model')
end

% get maximum for galactose import
% Raffinose
MWRaf = 504.46; % [g/mol]
MWGal = 180.156; % [g/mol]
MWSuc = 342.2965; % [g/mol]
wv = (MWRaf/1000)*concentration; % [g/l]
ratioGal = (MWGal/(MWSuc+MWGal));
concGal = (1000*ratioGal*wv)/MWGal; % [mM]
uptakeGalRaffinose = (vMaxFactor * 139 * concGal) / (0.8 + concGal);
% Melibiose
MWMel = 342.297; % [g/mol]
MWGal = 180.156; % [g/mol]
wv = (MWMel/1000)*concentration; % [g/l]
concGal = (1000*0.5*wv)/MWGal; % [mM]
uptakeGalMelibiose = (vMaxFactor * 139 * concGal) ./ (0.8 + concGal);

clear concGal MWRaf MWGal MWSuc wv ratioGal concGal MWMel
uptakeFluxes = [
    (vMaxFactor * 173 * concentration) / (0.7 + concentration);... D-Glucose
    (vMaxFactor * 260 * concentration) / (8.7 + concentration);... D-Fructose
    max(uptakeGalRaffinose,uptakeGalMelibiose)... maximum for Gal from Raffinose and Melibiose
];

clear vMaxFactor uptakeGalRaffinose uptakeGalMelibiose

% assign upper bounds on import fluxes
model.ub(transRxnIdx) = uptakeFluxes;

% add zero kcats for the uptake reactions
kcats(end:end+numel(carbonSources)) = 0;

% ~~~~~~~~~~~~~~~ sampling iterations ~~~~~~~~~~~~~~~ %
n = 5000;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Loop over developmental stages
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if new
    fprintf('\n> starting with growth simluation using transcriptomic data sets\n\n')
    
    % initialize matrix for optimal growth rates for mean, mean+sd, mean-sd
    growthMat = zeros(3,nStages);
    
    for i=1:nStages
        
        
        disp('~~~~~~~~~~~~~~~~~~~~~~~~')
        fprintf('Developmental stage: %s\n', experiments{i})
        disp('~~~~~~~~~~~~~~~~~~~~~~~~')
        
        % fraction of total protein mass that is is accounted for in the model
        [f, MW] = getAccountedProteinModel(model, uniProtFile, transcriptomicFiles{i});
        fprintf('Accounted mass fraction: %.3f\n', f)
        f = 1;%0.5;
        fprintf('f set to %.1f\n', f)
        
        % ~~~~~~~~~~~~~~~~~~~~~~ 1. FBA ~~~~~~~~~~~~~~~~~~~~~~ %
        disp('> Flux Balance Analysis')
        
        % +- standard deviation: 
        % rescale biomass coefficients to protein content
        C_tmp = C + C_sd;
        tmpModel = rescaleBiomassCoefficients(model,'m0995[c0]',C_tmp*f);
        growthPlusSd = simulateGrowthVmax(tmpModel, kcats, transcriptomicFiles{i},...
            C, f, MW);
        C_tmp = C - C_sd;
        
        % rescale biomass coefficients to protein content
        tmpModel = rescaleBiomassCoefficients(model,'m0995[c0]',C_tmp*f);
        growthMinusSd = simulateGrowthVmax(tmpModel, kcats, transcriptomicFiles{i},...
            C, f, MW);
        clear C_tmp tmpModel
        
        % mean protein content:
        
        % rescale biomass coefficients to protein content
        model = rescaleBiomassCoefficients(model,'m0995[c0]',C*f);

        [growth,v,ecModel] = simulateGrowthVmax(model, kcats, transcriptomicFiles{i},...
            C, f, MW);
        
        growthMat(:,i) = [growth; growthMinusSd; growthPlusSd];
        
        % ~~~~~~~~~~~~~~~~~~~~~~ 2. FVA ~~~~~~~~~~~~~~~~~~~~~~ %
        disp('> Flux Variability Analysis')
        ecModel.lb(ecModel.c==1) = growth;
        
        [minFlux, maxFlux] = fva(ecModel);
        ecModel.lb(ecModel.c==1) = 0;
        
        % ~~~~~~~~~~~~~~~~~~~ 3. sampling ~~~~~~~~~~~~~~~~~~~~ %
        disp(['> Sampling ',num2str(n),' flux distributions'])
        fluxSamples = distSampling(ecModel,n,minFlux,maxFlux);

        % ~~~~~~~~~~~~~~~~ 4. write results ~~~~~~~~~~~~~~~~~~ %
        
        % write FBA and FVA results to file
        writetable(array2table([v,minFlux,maxFlux],'RowNames',model.rxns,...
            'VariableNames', {'fbaFlux','minFlux','maxFlux'}),...
            [outDir,'fva-',experiments{i},'.csv'],...
            'WriteRowNames',true,'WriteVariableNames',true,'Delimiter','\t');
        
        % write sampling results to file
        writetable(array2table(fluxSamples,'RowNames',model.rxns,...
            'VariableNames',strcat('iter_',strtrim(cellstr(num2str((1:n)'))))),...
            [outDir,'samples-',experiments{i},'.csv'],...
            'WriteRowNames',true,'WriteVariableNames',true,'Delimiter','\t');
        
        clear minFlux maxFlux growth fluxSamples ecModel v
        
        fprintf('\n')
    end; clear ecModel f MW C
    
    % write matrix with growth rates to file
    writetable(array2table(growthMat,'RowNames',{'av','av+sd','av-sd'},...
            'VariableNames',experiments),...
            [outDir,'growth-rates-dev-stages.csv'],...
            'WriteRowNames',true,'WriteVariableNames',true,'Delimiter','\t');
    
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% ANALYSIS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
fluxSamplingMat = zeros(nRxns,n*nStages);
colIdx=1:n;

% read sampling results
for i=1:nStages
    tmpResTab = readtable([outDir,'samples-',experiments{i},'.csv'],...
        'ReadVariableNames',true,'ReadRowNames',true,'Delimiter','\t');
    fluxSamplingMat(:,colIdx+(i-1)*n) = table2array(tmpResTab);
end
clear tmpResTab

% ~~~~~~ sampling and anova + post-hoc Tukey test ~~~~~ %
disp('sampling and anova + post-hoc Tukey test')
comparisonNames = {'ERM_vs_HYP', 'ERM_vs_ARB', 'HYP_vs_ARB'};
alpha = 0.05;
pStage = ones(nRxns,1);
pMultComp = ones(nRxns,sum(1:(nStages-1)));

for i=1:nRxns
    % one-way anova per reaction
    anovaMat = fluxSamplingMat(i,:);
    anovaMat = reshape(anovaMat,n,nStages);
    [pStage(i),~,stats] = anova1(anovaMat,1:3,'off');
    
    % comparisons row-wise: 1 vs 2; 1 vs 3; 2 vs 3 (alternative:
    % significant difference in means)
    c = multcompare(stats,'Display','off');
    pMultComp(i,:) = c(:,6)';
    
end; clear anovaMat

% MHT correction (Bonferroni)
alpha=alpha/numel(pMultComp);

% MHT correction (Benjamini-Hochberg)
% pMultComp = reshape(pMultComp, numel(pMultComp),1);
% pMultComp = mafdr(pMultComp,'BHFDR', true);
% pMultComp = reshape(pMultComp, nRxns, sum(1:(nStages-1)));

% find subsystems for reactions, which show a significant difference between two stages
varSubsystems = repmat({''}, nStages, 1);
for i=1:nStages
    idxComp = pMultComp(:,i)<alpha;
    varSubsystems{i} = vertcat(model.subSystems{idxComp});
end
% unique set of subsystems
uniqueSubSystems = unique(vertcat(varSubsystems{:}));

% count occurrence per subsystem
subsystemCount = zeros(nStages,numel(uniqueSubSystems));

if all(~cellfun(@isempty,varSubsystems))
    for i=1:nStages
        subsystemCount(i,:) = cellfun(@(x)sum(ismember(varSubsystems{i},x)), uniqueSubSystems);
    end
end

% enrichment analysis for subsystems
N = sum(sum(subsystemCount));
p_up = ones(size(subsystemCount));
p_down = ones(size(subsystemCount));
alpha = 0.05;

for i=1:size(subsystemCount,1)
    for j=1:size(subsystemCount,2)
        
        n_11 = subsystemCount(i,j);
        n__1 = sum(subsystemCount(:,j));
        n_1_ = sum(subsystemCount(i,:));
        
        % Fisher's exact test for enrichment and depletion
        X = [n_11, n_1_-n_11;...
            n__1-n_11,N-n_11-(n_1_-n_11)-(n__1-n_11)];
        [~,p_down(i,j)] = fishertest(X, 'Tail', 'left');
        [~,p_up(i,j)] = fishertest(X, 'Tail', 'right');
    end
end

% MHT correction (Bonferroni)
alpha = alpha / numel(p_up);

% MHT correction (Benjamini-Hochberg)
% p_up = reshape(p_up, numel(p_up),1);
% p_up = mafdr(p_up,'BHFDR', true);
% p_up = reshape(p_up, size(subsystemCount));
% 
% p_down = reshape(p_down, numel(p_down),1);
% p_down = mafdr(p_down,'BHFDR', true);
% p_down = reshape(p_down, size(subsystemCount));

fprintf('\nenriched:\t\t%d\n', sum(any(p_up<alpha)))
if sum(any(p_up<alpha))>0
    fprintf('%s\n*\n',strjoin(uniqueSubSystems(any(p_up<alpha,1)),'\n'))
    
    % write enrichment results to file
    % enrichment
    writetable(array2table(p_up(:,any(p_up<alpha),1),...
        'VariableNames',  regexprep(uniqueSubSystems(any(p_up<alpha,1)), ' ', '_'),...
        'RowNames', comparisonNames),...
        [outDir, 'enriched-subsystems-dev-stages.csv'],...
        'WriteVariableNames', true, 'WriteRowNames', true,...
        'Delimiter', '\t');
    
end

fprintf('depleted:\t\t%d\n', sum(any(p_down<alpha)))
if sum(any(p_down<alpha))>0
    fprintf('%s\n*\n',strjoin(uniqueSubSystems(any(p_down<alpha,1)),'\n'))
    
    % depletion
    writetable(array2table(p_down(:,any(p_down<alpha),1),...
        'VariableNames',  regexprep(uniqueSubSystems(any(p_down<alpha,1)), ' ', '_'),...
        'RowNames', comparisonNames),...
        [outDir, 'depleted-subsystems-dev-stages.csv'],...
        'WriteVariableNames', true, 'WriteRowNames', true,...
        'Delimiter', '\t');
    
end


% ~~~ find reactions with large effect size between stages ~~~ %
% calculate non-parametric estimator for common language A_w
A_w = zeros(nRxns,0.5*nStages*(nStages-1));

for rxnIdx=1:nRxns
    c=0;
    for i=1:nStages-1
        for j=i+1:nStages
            c=c+1;
            p = fluxSamplingMat(rxnIdx,(i-1)*n+1:i*n);
            q = fluxSamplingMat(rxnIdx,(j-1)*n+1:j*n);
            
            A_w(rxnIdx,c) = sum(arrayfun(@(x)sum(x>q) + .5*sum(x==q),p)) / n^2;
        end
    end
    if mod(i,500)==0
        fprintf('calculated A_w for %d reactions\n', i)
    end
end

% write effect sizes to file
writetable(cell2table([model.rxns, model.rxnNames,...
    vertcat(model.subSystems{:}), num2cell(A_w)]),...
    [outDir, 'effect-size-table.tsv'],'WriteVariableNames',false,...
    'FileType','text')


largeEffectIdx = A_w>0.95;
largeEffectRxns = repmat({'-'},max(sum(largeEffectIdx)),size(A_w,2));
for i=1:size(A_w,2)
%     tmpNames = unique(model.rxnNames(largeEffectIdx(:,i)));
    tmpNames = unique(model.rxnKEGGID(largeEffectIdx(:,i)));
    largeEffectRxns(1:numel(tmpNames),i)=tmpNames;
end

% write reaction names with large effect size to file
writetable(cell2table(largeEffectRxns,'VariableNames',comparisonNames),...
    [outDir, 'large-effect-rxns.csv'],...
    'WriteVariableNames', true, 'WriteRowNames', true,...
    'Delimiter', '\t');

% find reactions with large effect sizes wrt to fluxes between stages

fprintf('total ERM - IRM: %d\n', sum(~ismember(largeEffectRxns(:,1),'-')))
fprintf('total ERM - ARB: %d\n', sum(~ismember(largeEffectRxns(:,2),'-')))
fprintf('total IRM - ARB: %d\n', sum(~ismember(largeEffectRxns(:,3),'-')))

fprintf('unique ERM - IRM: %d\n', numel(setdiff(largeEffectRxns(:,1), largeEffectRxns(:,[2 3]))))
fprintf('unique ERM - ARB: %d\n', numel(setdiff(largeEffectRxns(:,2), largeEffectRxns(:,[1 3]))))
fprintf('unique IRM - ARB: %d\n', numel(setdiff(largeEffectRxns(:,3), largeEffectRxns(:,[1 2]))))

fprintf('intersect comp 1 -- 2 : %d\n', numel(intersect(largeEffectRxns(:,1),largeEffectRxns(:,2))))
fprintf('intersect comp 1 -- 3 : %d\n', numel(intersect(largeEffectRxns(:,1),largeEffectRxns(:,3))))
fprintf('intersect comp 2 -- 3 : %d\n', numel(intersect(largeEffectRxns(:,2),largeEffectRxns(:,3))))

fprintf('intersect all : %d\n', numel(intersect(largeEffectRxns(:,1),...
    intersect(largeEffectRxns(:,2),largeEffectRxns(:,3)))))



