function [perf, result, testlabel] = mv_classify_timextime(cfg, X, clabel, X2, clabel2)
% Time x time generalisation. A classifier is trained on the training data
% X and validated on either the same dataset X. Cross-validation is
% recommended to avoid overfitting. If another dataset X2 is provided,
% the classifier is trained on X and tested on X2. No cross-validation is
% performed in this case since the datasets are assumed to be independent.
%
% Usage:
% perf = mv_classify_timextime(cfg,X,clabel,<X2, clabel2>)
%
%Parameters:
% X              - [samples x features x time points] data matrix
% clabel         - [samples x 1] vector of class labels containing
%                  1's (class 1) and 2's (class 2)
% X2, clabel2    - (optional) second dataset with associated labels. If
%                  provided, the classifier is trained on X and tested on
%                  X2 using
%
% cfg          - struct with optional parameters:
% .classifier   - name of classifier, needs to have according train_ and test_
%                 functions (default 'lda')
% .param        - struct with parameters passed on to the classifier train
%                 function (default [])
% .metric       - classifier performance metric, default 'accuracy'. See
%                 mv_classifier_performance. If set to [] or 'none', the 
%                 raw classifier output (labels, dvals or probabilities 
%                 depending on cfg.output_type) for each sample is returned. 
% .time1        - indices of training time points (by default all time
%                 points in X are used)
% .time2        - indices of test time points (by default all time points
%                 in X are used)
% .balance      - for imbalanced data with a minority and a majority class.
%                 'oversample' oversamples the minority class
%                 'undersample' undersamples the minority class
%                 such that both classes have the same number of samples
%                 (default 'none'). Note that for we undersample at the
%                 level of the repeats, whereas we oversample within each
%                 training set (for an explanation see mv_balance_classes)
%                 You can also give an integer number for undersampling.
%                 The samples will be reduced to this number. Note that
%                 concurrent over/undersampling (oversampling of the
%                 smaller class, undersampling of the larger class) is not
%                 supported at the moment
% .replace      - if balance is set to 'oversample' or 'undersample',
%                 replace deteremines whether data is drawn with
%                 replacement (default 1)
% .normalise    - normalises the data across samples, for each time point 
%                 and each feature separately, using 'zscore' or 'demean' 
%                 (default 'zscore'). Set to 'none' or [] to avoid normalisation.
% .feedback     - print feedback on the console (default 1)
%
% CROSS-VALIDATION parameters:
% .cv           - perform cross-validation, can be set to 'kfold',
%                 'leaveout', 'holdout', or 'none' (default 'kfold')
% .k            - number of folds in k-fold cross-validation (default 5)
% .p            - if cv is 'holdout', p is the fraction of test samples
%                 (default 0.1)
% .stratify     - if 1, the class proportions are approximately preserved
%                 in each fold (default 1)
% .repeat       - number of times the cross-validation is repeated with new
%                 randomly assigned folds (default 1)
%
% Returns:
% perf          - time1 x time2 classification matrix of classification
%                 performances corresponding to the selected metric. If
%                 metric='none', perf is a [r x k x t] cell array of
%                 classifier outputs, where each cell corresponds to a test
%                 set, k is the number of folds, r is the number of 
%                 repetitions, and t is the number of training time points.
%                 Each cell contains [n x t2] elements, where n is the
%                 number of test samples and t2 is the number of test time
%                 points.
% result        - struct with fields describing the classification result.
%                 Can be used as input to mv_statistics and mv_plot_result
% testlabel     - [r x k] cell array of test labels. Can be useful if
%                 metric='none'

% (c) Matthias Treder 2017-18

X = double(X);
if nargin > 3
    X2 = double(X2);
end

mv_set_default(cfg,'classifier','lda');
mv_set_default(cfg,'param',[]);
mv_set_default(cfg,'metric','accuracy');
mv_set_default(cfg,'time1',1:size(X,3));
mv_set_default(cfg,'normalise','zscore');
mv_set_default(cfg,'feedback',1);

% Cross-validation settings
mv_set_default(cfg,'cv','kfold');
mv_set_default(cfg,'repeat',5);
mv_set_default(cfg,'k',5);
mv_set_default(cfg,'p',0.1);
mv_set_default(cfg,'stratify',1);

switch(cfg.cv)
    case 'leaveout', cfg.k = size(X,1);
    case 'holdout', cfg.k = 1;
end

hasX2 = (nargin==5);
if hasX2, mv_set_default(cfg,'time2',1:size(X2,3));
else,     mv_set_default(cfg,'time2',1:size(X,3));
end

if any(ismember({'dval','auc','roc','tval'},cfg.metric))
    mv_set_default(cfg,'output_type','dval');
else
    mv_set_default(cfg,'output_type','clabel');
end

% Balance the data using oversampling or undersampling
mv_set_default(cfg,'balance','none');
mv_set_default(cfg,'replace',1);

% Set non-specified classifier parameters to default
cfg.param = mv_get_classifier_param(cfg.classifier, cfg.param);

[clabel, nclasses] = mv_check_clabel(clabel);
mv_check_cfg(cfg);

nTime1 = numel(cfg.time1);
nTime2 = numel(cfg.time2);

% Number of samples in the classes
n = arrayfun( @(c) sum(clabel==c) , 1:nclasses);

%% Reduce data to selected time points and normalise
X = X(:,:,cfg.time1);
X = mv_normalise(cfg.normalise, X);

if hasX2
    X2 = X2(:,:,cfg.time2);
    X2 = mv_normalise(cfg.normalise, X2);
end

%% Get train and test functions
train_fun = eval(['@train_' cfg.classifier]);
test_fun = eval(['@test_' cfg.classifier]);

%% Time x time generalisation
if ~strcmp(cfg.cv,'none') && ~hasX2
    % -------------------------------------------------------
    % One dataset X has been provided as input. X is hence used for both
    % training and testing. To avoid overfitting, cross-validation is
    % performed.
    if cfg.feedback, mv_print_classification_info(cfg,X,clabel); end

    % Save original data and labels in case we do over/undersampling
    X_orig = X;
    label_orig = clabel;
    
    % Initialise classifier outputs
    cf_output = cell(cfg.repeat, cfg.k, nTime1);
    testlabel = cell(cfg.repeat, cfg.k);
    
    for rr=1:cfg.repeat                 % ---- CV repetitions ----
        if cfg.feedback, fprintf('Repetition #%d. Fold ',rr), end
        
        % Undersample data if requested. We undersample the classes within the
        % loop since it involves chance (samples are randomly over-/under-
        % sampled) so randomly repeating the process reduces the variance
        % of the result
        if strcmp(cfg.balance,'undersample')
            [X,clabel] = mv_balance_classes(X_orig,label_orig,cfg.balance,cfg.replace);
        elseif isnumeric(cfg.balance)
            if numel(unique(sign(n - cfg.balance)))==2
                error(['cfg.balance [%d] is in between the sample sizes in the classes %s. ' ...
                    'Concurrent over- and undersampling is currently not supported.'],cfg.balance,mat2str(n))
            end
            % Sometimes we want to undersample to a specific
            % number (e.g. to match the number of samples across
            % subconditions)
            [X,clabel] = mv_balance_classes(X_orig,label_orig,cfg.balance,cfg.replace);
        end
        
        % Define cross-validation
        CV = mv_get_crossvalidation_folds(cfg.cv, clabel, cfg.k, cfg.stratify, cfg.p);
        
        for kk=1:CV.NumTestSets                      % ---- CV folds ----
            if cfg.feedback, fprintf('%d ',kk), end

            % Train data
            Xtrain = X(CV.training(kk),:,:,:);

            % Get train and test labels
            trainlabel= clabel(CV.training(kk));
            testlabel{rr,kk} = clabel(CV.test(kk));

            % Oversample data if requested. We need to oversample each
            % training set separately to prevent overfitting (see
            % mv_balance_classes for an explanation)
            if strcmp(cfg.balance,'oversample')
                [Xtrain,trainlabel] = mv_balance_classes(Xtrain,trainlabel,cfg.balance,cfg.replace);
            end

            % ---- Test data ----
            % Instead of looping through the second time dimension, we
            % reshape the data and apply the classifier to all time
            % points. We then need to apply the classifier only once
            % instead of nTime2 times.

            % Get test data
            Xtest= X(CV.test(kk),:,:);

            % permute and reshape into [ (trials x test times) x features]
            Xtest= permute(Xtest, [1 3 2]);
            Xtest= reshape(Xtest, CV.TestSize(kk)*nTime2, []);

            % ---- Training time ----
            for t1=1:nTime1

                % Training data for time point t1
                Xtrain_tt= squeeze(Xtrain(:,:,t1));

                % Train classifier
                cf= train_fun(cfg.param, Xtrain_tt, trainlabel);

                % Obtain classifier output (labels, dvals or probabilities)
                cf_output{rr,kk,t1} = reshape( mv_get_classifier_output(cfg.output_type, cf, test_fun, Xtest), sum(CV.test(kk)),[]);
            end

        end
        if cfg.feedback, fprintf('\n'), end
    end

    % Average classification performance across repeats and test folds
    avdim= [1,2];

elseif hasX2
    % -------------------------------------------------------
    % An additional dataset X2 has been provided. The classifier is trained
    % on X and tested on X2. Cross-validation does not make sense here and
    % is not performed.
    cfg.cv = 'none';
    
    % Undersample or oversample if requested
    if strcmp(cfg.balance,'undersample') || strcmp(cfg.balance,'oversample')
        [X,clabel] = mv_balance_classes(X, clabel,cfg.balance,cfg.replace);
    elseif isnumeric(cfg.balance)
        if numel(unique(sign(n - cfg.balance)))==2
            error(['cfg.balance [%d] is in between the sample sizes in the classes %s. ' ...
                'Concurrent over- and undersampling is currently not supported.'],cfg.balance,mat2str(n))
        end
        % Sometimes we want to undersample to a specific
        % number (e.g. to match the number of samples across
        % subconditions)
        [X,clabel] = mv_balance_classes(X, clabel, cfg.balance, cfg.replace);
    end
    
    % Print info on datasets
    if cfg.feedback, mv_print_classification_info(cfg, X, clabel, X2, clabel2); end

    % Initialise classifier outputs
    cf_output = nan(size(X2,1), nTime1, nTime2);

    % permute and reshape into [ (trials x test times) x features]
    Xtest= permute(X2, [1 3 2]);
    Xtest= reshape(Xtest, size(X2,1)*nTime2, []);

    % ---- Training time ----
    for t1=1:nTime1

        % Training data for time point t1
        Xtrain= squeeze(X(:,:,t1));

        % Train classifier
        cf= train_fun(cfg.param, Xtrain, clabel);

        % Obtain classifier output (labels or dvals)
        cf_output(:,t1,:) = reshape( mv_get_classifier_output(cfg.output_type, cf, test_fun, Xtest), size(X2,1),[]);

    end

    testlabel = clabel2;
    avdim = [];

elseif strcmp(cfg.cv,'none')
    % -------------------------------------------------------
    % One dataset X has been provided as input. X is hence used for both
    % training and testing. However, cross-validation is not performed.
    % Note that this can lead to overfitting.

    if cfg.feedback
        fprintf('Training and testing on the same dataset (note: this can lead to overfitting).\n')
    end

    % Initialise classifier outputs
    cf_output = nan(size(X,1), nTime1, nTime2);

    % permute and reshape into [ (trials x test times) x features]
    Xtest= permute(X, [1 3 2]);
    Xtest= reshape(Xtest, size(X,1)*nTime1, []);
    % permute and reshape into [ (trials x test times) x features]
  
    % ---- Training time ----
    for t1=1:nTime1

        % Training data for time point t1
        Xtrain= squeeze(X(:,:,t1));

        % Train classifier
        cf= train_fun(cfg.param, Xtrain, clabel);

        % Obtain classifier output (labels or dvals)

        cf_output(:,t1,:) = reshape( mv_get_classifier_output(cfg.output_type, cf, test_fun, Xtest), size(X,1),[]);

    end

    testlabel = clabel;
    avdim = [];

end

if isempty(cfg.metric) || strcmp(cfg.metric,'none')
    if cfg.feedback, fprintf('No performance metric requested, returning raw classifier output.\n'), end
    perf = cf_output;
    perf_std = [];
else
    if cfg.feedback, fprintf('Calculating classifier performance... '), end
    [perf, perf_std] = mv_calculate_performance(cfg.metric, cfg.output_type, cf_output, testlabel, avdim);
    if cfg.feedback, fprintf('finished\n'), end
end

result = [];
if nargout>1
   result.function  = mfilename;
   result.perf      = perf;
   result.perf_std  = perf_std;
   result.metric    = cfg.metric;
   result.cv        = cfg.cv;
   result.k         = cfg.k;
   if hasX2
       result.n         = size(X2,1);
   else
       result.n         = size(X,1);
   end
   result.repeat    = cfg.repeat;
   result.nclasses  = nclasses;
   result.classifier = cfg.classifier;
end