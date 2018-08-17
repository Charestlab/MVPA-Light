function [X,clabel,Y,M] = simulate_gaussian_data(nsamples, nfeatures, nclasses, prop, scale, do_plot, M)
% Creates data randomly drawn from a multivariate Gaussian distribution.
% The class centroids are randomly place on the unit hypersphere in feature
% space.
% The multivariate covariance matrix is generated by randomly sampling from
% the Wishart distribution.
%
% Usage:  [X,clabel,Y,M] = simulate_gaussian_data(nsamples, nfeatures, nclasses, prop, scale, do_plot)
%
% Parameters:
% nsamples          - total number of samples (across all classes)
% nfeatures         - number of features
% nclasses          - number of classes (default 2)
% prop              - class proportions (default 'equal'). Otherwise give
%                     class proportions e.g. [0.2, 0.2, 0.6] gives 20% of
%                     the samples to class 1, 20% to class 2, and 60% to
%                     class 3
% scale             - variance scaling (default 1). For varm > 1, the
%                     variance is increased and hence discriminability of
%                     the classes is decreased. For 0 < varm < 1, the
%                     variance of the samples is decreased.
%                     varm can be a vector instead of a scalar, then each
%                     feature is scaled separately according to the entry
% do_plot           - if 1, plots the data using an LDA subspace projection
%                     to 2 dimensions
% M                 - class centroids. If not provided, they are randomly
%                     created
%
% Returns:
% X         - [nsamples x nfeatures] matrix of data
% clabel    - [nsamples x 1] vector of class labels (1's, 2's, etc)
% Y         - [samples x nclasses] indicator matrix that can be used
%             alongside or instead of clabel. Y(i,j)=1 if the i-th sample
%             belongs to class j, and Y(i,j)=0 otherwise.
% M         - [nfeatures x nclasses] true class centroids

% (c) Matthias Treder

if nargin<3 || isempty(nclasses), nclasses = 2; end
if nargin<4 || isempty(prop), prop = 'equal'; end
if nargin<5 || isempty(scale), scale = 2; end
if nargin<6 || isempty(do_plot), do_plot = 1; end
if nargin<7 || isempty(M), M = []; end

% Check input arguments
if nclasses > nfeatures, error('nclasses cannot be smaller than nfeatures'), end

if ischar(prop) && strcmp(prop,'equal') && ~(rem(nsamples, nclasses)==0)
    error('Class proportion is set to ''equal'' but number of samples cannot be divided by the number of classes')
end

if ~ischar(prop)
    if sum(prop) ~= 1
        error('prop must sum to 1')
    end
    if numel(prop) ~= nclasses
        error('number of elements in prop must match nclasses')
    end
end


X = nan(nsamples, nfeatures);
clabel = nan(nsamples,1);
Y = zeros(nsamples,nclasses);

% %% Generate class centroids [placed on the corners of a hypercube]
% M = nan(nfeatures, nclasses);
% 
% for cc=1:nclasses
%     m = round(rand(nfeatures,1));
%     
%     while cc>1 && any(all(bsxfun(@eq, M(:,1:cc-1),m)))
%         % brute force approach: if class mean is equal to one of the former
%         % class means we keep on randomly generating
%         m = round(rand(nfeatures,1));
%     end
%     
%     M(:,cc) = m;
% end
% clear m

%% Generate class centroids [randomy place on the surface of a n-dimensinal hypersphere]
if isempty(M)
    M = rand(nfeatures, nclasses);
    
    for cc=1:nclasses
        % Normalise the norm to put them on the surface of the hypersphere
        M(:,cc) = M(:,cc) / norm(M(:,cc));
    end
end

%% Generate random covariance matrix using the Wishart distribution
SIGMA = wishrnd( eye(nfeatures), 2*nfeatures);

% Scale diagonal
d = diag(SIGMA);
d = sqrt(scale(:))./sqrt(d);

% Perform scaling
SIGMA = diag(d) * SIGMA * diag(d);

%% Determine frequencies of each class
if ischar(prop) && strcmp(prop,'equal')
    nsamples_per_class = nsamples / nclasses * ones(1, nclasses);
else
    nsamples_per_class = nsamples * prop;
end

if ~all(mod(nsamples_per_class,1)==0)
    error('prop * nsamples must yield integer values')
end

%% Generate data and class labels
n = 1;

for cc=1:nclasses
    
    % Draw data from multivariate normal distribution
    X(n:n+nsamples_per_class(cc)-1,:) = mvnrnd(M(:,cc), SIGMA, nsamples_per_class(cc));
    
    % Set labels
    clabel(n:n+nsamples_per_class(cc)-1) = cc;
    
    % Set indicator matrix
    Y(n:n+nsamples_per_class(cc)-1, cc) = 1;
    
    n = n+nsamples_per_class(cc);
end

%% Plot data
if do_plot
    % -------------------------------------
    % Use LDA to project to two dimensions
    
    plotopt = {'.', 'MarkerSize', 12};
    
    % Calculate class means and sample mean
    mbar = mean(X);            % sample mean
    m = zeros(nclasses, nfeatures);       % class means
    for c=1:nclasses
        m(c,:) = mean(X(clabel==c,:));
    end

    % Between-classes scatter for multi-class
    Sb = zeros(nfeatures);
    for c=1:nclasses
        Sb = Sb + nsamples_per_class(c) * (m(c,:)-mbar)'*(m(c,:)-mbar);
    end
    
    % Within-class scatter
    Sw = zeros(nfeatures);
    for c=1:nclasses
        Sw = Sw + (nsamples_per_class(c)-1) * cov(X(clabel==c,:));
    end

    
    % Get discriminant axes
    [V,D] = eig(Sb,Sw);
    [d, so] = sort(diag(D),'descend');
    V = V(:,so(1:2));
    
    % Project data
    Xp = X*V;
    
    close all
    nCol = 2; nRow = 1;
    % Subplot 1: data projected on features 1 and 2
    subplot(nRow, nCol, 1)
    for cc=1:nclasses
        plot(X(clabel==cc,1),X(clabel==cc,2), plotopt{:})
        hold all
    end
    xlabel('Feature 1')
    ylabel('Feature 2')
    title('Projected on first two features')

    % Subplot 2: data projected on discriminant axes
    subplot(nRow, nCol, 2)
    for cc=1:nclasses
        plot(Xp(clabel==cc,1),Xp(clabel==cc,2), plotopt{:})
        hold all
    end
    xlabel('LDA 1')
    ylabel('LDA 2')
    title('Projected on linear discriminant subspace')

end
