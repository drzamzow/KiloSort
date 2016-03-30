if ~exist('initialized', 'var')
    addpath('C:\CODE\MariusBox\Primitives\')
    rng(1);
    
    Nfilt 	= ops.Nfilt; %256+128;
    nt0 	= 61;
    ntbuff  = ops.ntbuff;
    NT  	= ops.NT;

    Nrank   = ops.Nrank;
    Th 		= ops.Th;
    maxFR 	= ops.maxFR;
    
    Nchan 	= ops.Nchan;
    
    batchstart = 0:NT:NT*(Nbatch-Nbatch_buff);
    
    delta = NaN * ones(Nbatch, 1);
    iperm = randperm(Nbatch);
    
    switch ops.initialize
        case 'fromData'
            U = Uinit(:, 1:Nfilt, :);
            W = Winit(:, 1:Nfilt, :);
            mu = muinit(1:Nfilt);
        otherwise
            initialize_waves0;
            ipck = randperm(size(Winit,2), Nfilt);
            W = [];
            U = [];
            for i = 1:Nrank
                W = cat(3, W, Winit(:, ipck)/Nrank);
                U = cat(3, U, Uinit(:, ipck));
            end
            W = alignW(W);
            for k = 1:Nfilt
                wu = squeeze(W(:,k,:)) * squeeze(U(:,k,:))';
                newnorm = sum(wu(:).^2).^.5;
                W(:,k,:) = W(:,k,:)/newnorm;
            end
            mu = 7 * ones(Nfilt, 1, 'single');
    end
    
    
    nspikes = zeros(Nfilt, Nbatch);
    lam =  ones(Nfilt, 1, 'single');
    
    freqUpdate = 4 * 50;
    iUpdate = 1:freqUpdate:Nbatch;

    
    dbins = zeros(100, Nfilt);
    dsum = 0;
    miniorder = repmat(iperm, 1, ops.nfullpasses);
%     miniorder = repmat([1:Nbatch Nbatch:-1:1], 1, ops.nfullpasses/2);    


    gpuDevice(1);   
    
    % the only GPU variable that continues across iterations
    dWU = gpuArray.zeros(nt0, Nchan, Nfilt, 'single');
    U0 = gpuArray(U);
    utu = gpuArray.zeros(Nfilt, 'single');
    for irank = 1:Nrank
        utu = utu + (U0(:,:,irank)' * U0(:,:,irank));
    end
%     utu(isnan(utu)) = 0;
    UtU = logical(utu);
    clear utu
    
    i = 1;
    initialized = 1;
    
end


%%
% pmi = exp(-1./exp(linspace(log(ops.momentum(1)), log(ops.momentum(2)), Nbatch*ops.nannealpasses)));
pmi = exp(-1./linspace(1/ops.momentum(1), 1/ops.momentum(2), Nbatch*ops.nannealpasses));
% pmi = exp(-linspace(ops.momentum(1), ops.momentum(2), Nbatch*ops.nannealpasses));

% pmi  = linspace(ops.momentum(1), ops.momentum(2), Nbatch*ops.nannealpasses);
Thi  = linspace(ops.Th(1),                 ops.Th(2), Nbatch*ops.nannealpasses);
if ops.lam(1)==0
    lami = linspace(ops.lam(1), ops.lam(2), Nbatch*ops.nannealpasses); 
else
    lami = exp(linspace(log(ops.lam(1)), log(ops.lam(2)), Nbatch*ops.nannealpasses));
end
 
if Nbatch_buff<Nbatch
    fid = fopen(fullfile(root, fnameTW), 'r');
end

st3 = [];

nswitch = [0];
msg = [];
fprintf('Time %3.0fs. Optimizing templates ...\n', toc)
while (i<=Nbatch * ops.nfullpasses+1)    
    % set the annealing parameters
    if i<Nbatch*ops.nannealpasses
        Th      = Thi(i);
        lam(:)  = lami(i);
        pm      = pmi(i);
    end
    
    % some of the parameters change with iteration number
    Params = double([NT Nfilt Th maxFR 10 Nchan Nrank pm]);    
    
    % update the parameters every freqUpdate iterations
    if i>1 &&  ismember(rem(i,Nbatch), iUpdate) %&& i>Nbatch        
        %
        % parameter update    
        dWUtot = gather(dWU);
        
        [W, U, mu, UtU] = update_params(mu, W, U, dWUtot, nspikes) ;        
        
        % align except on last estimation
        if i<Nbatch * ops.nfullpasses; W = alignW(W); end
        
        % break if last iteration reached
        if i>Nbatch * ops.nfullpasses; break; end
        
        % record the error function for this iteration
        rez.errall(ceil(i/freqUpdate))          = nanmean(delta);
       
        % break bimodal clusters and remove low variance clusters
        if ops.shuffle_clusters && i>Nbatch && rem(rem(i,Nbatch), 4*400)==1
           [W, U, mu, dWUtot, dbins, nswitch] = ...
               replace_clusters(dWUtot,W,U, mu, dbins, dsum, ...
               Nbatch, ops.mergeT, ops.splitT, Winit, Uinit, muinit);
        end
        
        % plot (if option) the decay of spike amplitude
        plot(sort(mu)); axis tight;
        title(sprintf('%d  ', nswitch)); drawnow;
    end

    % select batch and load from RAM or disk
    ibatch = miniorder(i);
    if ibatch>Nbatch_buff
        offset = 2 * ops.Nchan*batchstart(ibatch-Nbatch_buff);
        fseek(fid, offset, 'bof');
        dat = fread(fid, [NT ops.Nchan], '*int16');
    else
       dat = DATA(:,:,ibatch); 
    end
    
    % move data to GPU and scale it
    dataRAW = gpuArray(dat);
    dataRAW = single(dataRAW);
    dataRAW = dataRAW / ops.scaleproc;
    
    % project data in low-dim space 
%     data = gpuArray.zeros(NT, Nfilt, Nrank, 'single');
%     for irank = 1:Nrank
%         data(:,:,irank) 	= dataRAW * U(:,:,irank); 
%     end
%     data = reshape(data, NT, Nfilt*Nrank);
    data = dataRAW * U(:,:);
    %
    % run GPU code to get spike times and coefficients
    [dWU, st, id, x,Cost, nsp] = ...
        mexMPregMU(Params,dataRAW,W,data,UtU,mu, lam .* (20./mu).^2, dWU);
    %
    % compute numbers of spikes
    nsp                = gather(nsp(:));
    nspikes(:, ibatch) = nsp;
    
    % bin the amplitudes of the spikes
    xround = min(max(1, round(int32(x))), 100);
    
    % this is a hard-coded forgetting factor, needs to become an option
    dbins = .9975 * dbins;
    dbins(xround + id * size(dbins,1)) = dbins(xround + id * size(dbins,1)) + 1;
    
    % update estimate of amplitude distribution
    dsum = .9975 * dsum +  .0025;
    
    % factor by which to update each cell depends on how many spikes    
%     npm    = pm.^nsp .* npm    + (1-pm.^nsp) .* nsp;
    
    % estimate cost function at this time step
    delta(ibatch) = sum(Cost)/1e6;
    
    % update status
    if rem(i,400)==1
        nsort = sort(sum(nspikes,2), 'descend');
        fprintf(repmat('\b', 1, numel(msg)));
        msg = sprintf('Time %2.2f, batch %d/%d, mu %2.2f, neg-err %2.6f, NTOT %d, n100 %d, n200 %d, n300 %d, n400 %d\n', ...
            toc, i,Nbatch* ops.nfullpasses,nanmedian(mu(:)), nanmean(delta), sum(nspikes(:)), ...
            nsort(min(size(W,2), 100)), nsort(min(size(W,2), 200)), ...
                nsort(min(size(W,2), 300)), nsort(min(size(W,2), 400)));
        fprintf(msg);        
    end
    
    % increase iteration counter
    i = i+1;
end

% close the data file if it has been used
if Nbatch_buff<Nbatch
    fclose(fid);
end


