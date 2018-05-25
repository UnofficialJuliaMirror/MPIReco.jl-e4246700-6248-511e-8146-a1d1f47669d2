import Base: size
import LinearSolver: initkaczmarz, dot_with_matrix_row, kaczmarz_update!

export reconstructionMultiPatch, FFOperator


# Necessary for Multi-System-Matrix FF reconstruction
voxelSize(bSF::MultiMPIFile) = voxelSize(bSF[1])
sfGradient(bSF::MultiMPIFile,dim) = sfGradient(bSF[1],dim)
generateHeaderDict(bSF::MultiMPIFile,bMeas::MPIFile) =
   generateHeaderDict(bSF[1],bMeas)


 function reconstructionMultiPatch(bSF, bMeas::MPIFile;
   minFreq=0, maxFreq=1.25e6, SNRThresh=-1,maxMixingOrder=-1, numUsedFreqs=-1, sortBySNR=false, recChannels=1:numReceivers(bMeas),
   kargs...)

   freq = filterFrequencies(bSF,minFreq=minFreq, maxFreq=maxFreq,recChannels=recChannels, SNRThresh=SNRThresh, numUsedFreqs=numUsedFreqs, sortBySNR=sortBySNR)

   println("Frequency Selection: ", length(freq), " frequencies")

   return reconstructionMultiPatch(bSF, bMeas, freq; kargs...)
 end

function reconstructionMultiPatch(bSF, bMeas::MPIFile, freq;
            frames=nothing, bEmpty=nothing,
            nAverages=1, loadas32bit=false,
            spectralLeakageCorrection=true,
            roundPatches = false, 
            FFPos = zeros(0,0), FFPosSF = zeros(0,0), 
            mapping=zeros(0), mirror=zeros(0,0), kargs...)

  FFPos_ = ffPos(bMeas)
  
  #consistenceCheck(bSF, bMeas)

  bgcorrection = (bEmpty != nothing)

  periodsSortedbyFFPos = unflattenOffsetFieldShift(FFPos_)

  FFPos_ = FFPos_[:,periodsSortedbyFFPos[:,1]]
  
  if length(FFPos) > 0 
    FFPos_[:] = FFPos
  end
  
  if length(FFPosSF) == 0
    FFPosSF_ = [vec(ffPos(SF)) for SF in bSF]
  else
    FFPosSF_ = [vec(FFPosSF[:,l]) for l=1:size(FFPosSF,2)]
  end

  gradient = acqGradient(bMeas)[:,:,1,periodsSortedbyFFPos[:,1]]


  FFOp = FFOperator(bSF,bMeas,freq,bgcorrection,
                    FFPos=FFPos_,
                    gradient=gradient,
                    roundPatches=roundPatches,
                    FFPosSF=FFPosSF_,
                    mapping=mapping,
                    mirror=mirror)

  L = numScans(bMeas)
  (frames==nothing) && (frames=collect(1:L))
  nFrames=length(frames)


  uTotal = getMeasurementsFD(bMeas,frequencies=freq, frames=frames, numAverages=nAverages,
                             spectralLeakageCorrection=spectralLeakageCorrection)

  uTotal=uTotal[:,periodsSortedbyFFPos,:]
  uTotal=mean(uTotal,3)

  # Here we call a regular reconstruction function
  c = reconstruction(FFOp,uTotal,(shape(FFOp.grid)...,); kargs...)

  pixspacing = voxelSize(bSF) ./ sfGradient(bMeas,3) .* sfGradient(bSF,3)
  offset = fieldOfViewCenter(FFOp.grid)  .- 0.5.*fieldOfView(FFOp.grid) .+ 0.5.*spacing(FFOp.grid)

  shape_ = size(c)
  x=Axis{:x}(range(offset[1],pixspacing[1],shape_[1]))
  y=Axis{:y}(range(offset[2],pixspacing[2],shape_[2]))
  z=Axis{:z}(range(offset[3],pixspacing[3],shape_[3]))
  t=Axis{:time}(range(0.0,dfCycle(bMeas),L))
  im = AxisArray(c,x,y,z,t)  
  
  #im = AxisArray(c, (:x,:y,:z,:time), tuple(pixspacing...,dfCycle(bMeas)),
  #                                    tuple(offset...,0.0))

  imMeta = ImageMeta(im,generateHeaderDict(bSF,bMeas))
  return imMeta
end


# FFOperator is a type that acts as the MPI system matrix but exploits
# its sparse structure.
# Its very important to keep this type typestable
type FFOperator{V<:AbstractMatrix, T<:Positions}
  S::Vector{V}
  grid::T
  N::Int
  M::Int
  RowToPatch::Vector{Int}
  xcc::Vector{Vector{Int}}
  xss::Vector{Vector{Int}}
  sign::Matrix{Int}
  nPatches::Int
  patchToSMIdx::Vector{Int}
end


function FFOperator(SF::MPIFile, bMeas, freq, bgcorrection::Bool; kargs...)
  return FFOperator(MultiMPIFile([SF]), bMeas, freq, bgcorrection; kargs...)
end

function findNearestPatch(ffPosSF, FFPos, gradientSF, gradient)
  idx = -1
  minDist = 1e20
  for (l,FFPSF) in enumerate(ffPosSF)
    if gradientSF[l][:,:,1,1] == gradient
      dist = norm(FFPSF.-FFPos)
      if dist < minDist
        minDist = dist
        idx = l
      end
    end
  end
  if idx < 0
    error("Something went wrong")
  end
  return idx
end

function FFOperator(SFs::MultiMPIFile, bMeas, freq, bgcorrection::Bool; 
        mapping=zeros(0), kargs...)
  if length(mapping) > 0
    return FFOperatorExpliciteMapping(SFs,bMeas,freq,bgcorrection; mapping=mapping, kargs...)
  else
    return FFOperatorRegular(SFs,bMeas,freq,bgcorrection; kargs...)
  end
end

function FFOperatorExpliciteMapping(SFs::MultiMPIFile, bMeas, freq, bgcorrection::Bool;
                    denoiseWeight=0, FFPos=zeros(0,0), FFPosSF=zeros(0,0),
                    gradient=zeros(0,0,0),
                    roundPatches = false, 
                    mapping=zeros(0), mirror=zeros(0,0), kargs...)

  println("Load SF")
  numPatches = size(FFPos,2)
  M = length(freq)
  RowToPatch = kron(collect(1:numPatches), ones(Int,M))

  S = [getSF(SF,freq,nothing,"kaczmarz", bgcorrection=bgcorrection) for SF in SFs]

  gradientSF = [acqGradient(SF) for SF in SFs]

  grids = RegularGridPositions[]
  patchToSMIdx = mapping
  
  mirroring = length(mirror) > 0
  if !mirroring
    mirror = ones(Int,3,numPatches)
  else
    mixFactors = mixingFactors(SFs[1])
  end
  
  sign = ones(Int, M, numPatches)
   
  # We first check which system matrix fits best to each patch. Here we use only
  # those system matrices where the gradient matches. If the gradient matches, we take
  # the system matrix with the closes focus field shift
  for k=1:numPatches
    idx = mapping[k]
    SF = SFs[idx]
    
    diffFFPos = mirror[:,k].*FFPosSF[idx] .- FFPos[:,k] 
    
    if any(mirror .< 0) # in case of mirroring we do not allow shifting
      diffFFPos[:] = 0
    end

    push!(grids, RegularGridPositions(calibSize(SF),calibFov(SF),
          mirror[:,k].*calibFovCenter(SF).-diffFFPos, mirror[:,k]))
          
    if mirroring
      numAllFreq = rxNumFrequencies(SF)
      for l=1:length(freq)
        chan = div(freq[l],numAllFreq) + 1
        idx = mod1(freq[l],numAllFreq)
        mx = mixFactors[l,1]
        my = mixFactors[l,2]
        mz = mixFactors[l,3]
        
        if mirror[1,k]<0 && mirror[3,k]<0
         a = mx+mz+1
         if chan == 2
           a -= 1
         end
        elseif mirror[1,k]<0 && mirror[3,k]>0
         a = mx
         if chan == 1
           a += 1
         end        
        elseif mirror[1,k]>0 && mirror[3,k]<0
         a = mz
         if chan == 3
           a += 1
         end
        else
          a = 0
        end
        sign[l,k] =  (-1)^a
    #ChnX        (-1)^(mx+1)        (-1)^mz            (-1)^(mx+1+mz)
    #ChnY        (-1)^(mx)            (-1)^mz             (-1)^(mx+mz)
    #ChnZ        (-1)^(mx)            (-1)^(mz+1)      (-1)^(mx+mz+1)
      end
    end
  end

  # We now know all the subgrids for each patch, if the corresponding system matrix would be taken as is
  # and if a possible focus field missmatch has been taken into account (by changing the center)
  println("Calc Reco Grid")
  recoGrid = RegularGridPositions(grids)


  # Within the next loop we will refine our grid since we now know our reconstruction grid
  for k=1:numPatches
    idx = mapping[k]
    SF = SFs[idx]

    issubgrid = isSubgrid(recoGrid,grids[k])
    println(" issubgrid = $issubgrid")
    println(grids[k])
    if !issubgrid 
      grids[k] = deriveSubgrid(recoGrid, grids[k])
    end
    println(grids[k])
  end
  println("Use $(length(S)) patches")

  println("Calc LUT")
  # now that we have all grids we can calculate the indices within the recoGrid
  xcc, xss = calculateLUT(grids, recoGrid)
  
  println("Finished")
  return FFOperator(S, recoGrid, length(recoGrid), M*numPatches,
             RowToPatch, xcc, xss, sign, numPatches, patchToSMIdx)
end

function FFOperatorRegular(SFs::MultiMPIFile, bMeas, freq, bgcorrection::Bool;
                    denoiseWeight=0, gradient=zeros(0,0,0),
                    roundPatches = false, FFPos=zeros(0,0), FFPosSF=zeros(0,0),
                    kargs...)

  println("Load SF")
  numPatches = size(FFPos,2)
  M = length(freq)
  RowToPatch = kron(collect(1:numPatches), ones(Int,M))

  S = AbstractMatrix[]
  SOrigIdx = Int[]
  SIsPlain = Bool[]

  gradientSF = [acqGradient(SF) for SF in SFs]

  grids = RegularGridPositions[]
  matchingSMIdx = zeros(Int,numPatches)
  patchToSMIdx = zeros(Int,numPatches)
  
  # We first check which system matrix fits best to each patch. Here we use only
  # those system matrices where the gradient matches. If the gradient matches, we take
  # the system matrix with the closes focus field shift
  for k=1:numPatches
    idx = findNearestPatch(FFPosSF, FFPos[:,k], gradientSF, gradient[:,:,k])
    
    SF = SFs[idx]
    
    println("For patch $k at position $(FFPos[:,k]) I will use SM $idx with FFP $(FFPosSF[idx]) ")
    
    if isapprox(FFPosSF[idx],FFPos[:,k])
      diffFFPos = zeros(3)
    else
      diffFFPos = FFPosSF[idx] .- FFPos[:,k]
    end
    push!(grids, RegularGridPositions(calibSize(SF),calibFov(SF),calibFovCenter(SF).-diffFFPos))
    matchingSMIdx[k] = idx
  end

  # We now know all the subgrids for each patch, if the corresponding system matrix would be taken as is
  # and if a possible focus field missmatch has been taken into account (by changing the center)
  println("Calc Reco Grid")
  recoGrid = RegularGridPositions(grids)


  # Within the next loop we will refine our grid since we now know our reconstruction grid
  for k=1:numPatches
    idx = matchingSMIdx[k]
    SF = SFs[idx]

    issubgrid = isSubgrid(recoGrid,grids[k])
    if !issubgrid &&
       roundPatches &&
       spacing(recoGrid) == spacing(grids[k])
       
      issubgrid = true
      grids[k] = deriveSubgrid(recoGrid, grids[k])

    end

    # if the patch is a true subgrid we don't need to apply interpolation and can load the
    # matrix as is.
    if issubgrid
      # we first check if the matrix is already in memory
      u = -1
      for l=1:length(SOrigIdx)
        if SOrigIdx[l] == idx && SIsPlain[l]
          u = l
          break
        end
      end
      if u > 0 # its already in memory
        patchToSMIdx[k] = u
      else     # not yet in memory  -> load it
        S_ = getSF(SF,freq,nothing,"kaczmarz", bgcorrection=bgcorrection)
        push!(S,S_)
        push!(SOrigIdx,idx)
        push!(SIsPlain,true) # mark this as a plain system matrix (without interpolation)
        patchToSMIdx[k] = length(S)
      end
    else
      # in this case the patch grid does not fit onto the reco grid. Lets derive a subgrid
      # that is very similar to grids[k]
      newGrid = deriveSubgrid(recoGrid, grids[k])

      # load the matrix on the new subgrid
      S_ = getSF(SF,freq,nothing,"kaczmarz", bgcorrection=bgcorrection,
                   gridsize=shape(newGrid),
                   fov=fieldOfView(newGrid),
                   center=fieldOfViewCenter(newGrid).-fieldOfViewCenter(grids[k]))
                   # @TODO: I don't know the sign of aboves statement

      grids[k] = newGrid # we need to change the stored Grid since we now have a true subgrid
      push!(S,S_)
      push!(SOrigIdx,idx)
      push!(SIsPlain,false)
      patchToSMIdx[k] = length(S)
    end
  end
  println("Use $(length(S)) patches")

  println("Calc LUT")
  # now that we have all grids we can calculate the indices within the recoGrid
  xcc, xss = calculateLUT(grids, recoGrid)
  
  sign = ones(Int, M, numPatches)

  println("Finished")
  return FFOperator(S, recoGrid, length(recoGrid), M*numPatches,
             RowToPatch, xcc, xss, sign, numPatches, patchToSMIdx)
end


function calculateLUT(grids, recoGrid)
  xss = Vector{Int}[]
  xcc = Vector{Int}[]
  for k=1:length(grids)
    N = length(grids[k])
    push!(xss, collect(1:N))
    xc = zeros(Int64,N)
    for n=1:N
      xc[n] = posToLinIdx(recoGrid,grids[k][n])
    end
    push!(xcc, xc)
  end
  return xcc, xss
end

function size(FFOp::FFOperator,i::Int)
  if i==2
    return FFOp.N
  elseif i==1
    return FFOp.M
  else
    error("bounds error")
  end
end

length(FFOp::FFOperator) = size(FFOp,1)*size(FFOp,2)

### The following is intended to use the standard kaczmarz method ###

function calculateTraceOfNormalMatrix(Op::FFOperator, weights)
  if length(Op.S) == 1
    trace = calculateTraceOfNormalMatrix(Op.S[1],weights)
    trace *= Op.nPatches #*prod(Op.PixelSizeSF)/prod(Op.PixelSizeC)
  else
    trace = sum([calculateTraceOfNormalMatrix(S,weights) for S in Op.S])
    #trace *= prod(Op.PixelSizeSF)/prod(Op.PixelSizeC)
  end
  return trace
end

setlambda(::FFOperator, ::Real) = nothing

function dot_with_matrix_row{T}(Op::FFOperator, x::AbstractArray{T}, k::Integer)
  p = Op.RowToPatch[k]
  xs = Op.xss[p]
  xc = Op.xcc[p]

  j = mod1(k,div(Op.M,Op.nPatches))
  A = Op.S[Op.patchToSMIdx[p]]
  sign = Op.sign[j,Op.patchToSMIdx[p]]

  return dot_with_matrix_row_(A,x,xs,xc,j,sign)
end

function dot_with_matrix_row_{T}(A::AbstractArray{T},x,xs,xc,j,sign)
  tmp = zero(T)
  @simd  for i = 1:length(xs)
     @inbounds tmp += sign*A[j,xs[i]]*x[xc[i]]
  end
  tmp
end

function kaczmarz_update!(Op::FFOperator, x::AbstractArray, k::Integer, beta)
  p = Op.RowToPatch[k]
  xs = Op.xss[p]
  xc = Op.xcc[p]

  j = mod1(k,div(Op.M,Op.nPatches))
  A = Op.S[Op.patchToSMIdx[p]]
  sign = Op.sign[j,Op.patchToSMIdx[p]]

  kaczmarz_update_!(A,x,beta,xs,xc,j,sign)
end

function kaczmarz_update_!(A,x,beta,xs,xc,j,sign)
  @simd for i = 1:length(xs)
    @inbounds x[xc[i]] += beta* conj(sign*A[j,xs[i]])
  end
end

function initkaczmarz(Op::FFOperator,λ,weights::Vector)
  T = typeof(real(Op.S[1][1]))
  denom = zeros(T,Op.M)
  rowindex = zeros(Int64,Op.M)

  MSub = div(Op.M,Op.nPatches)

  if length(Op.S) == 1
    for i=1:MSub
      s² = rownorm²(Op.S[1],i)*weights[i]^2
      if s²>0
        for l=1:Op.nPatches
          k = i+MSub*(l-1)
          denom[k] = weights[i]^2/(s²+λ)
          rowindex[k] = k
        end
      end
    end
  else
    for l=1:Op.nPatches
      for i=1:MSub
        s² = rownorm²(Op.S[Op.patchToSMIdx[l]],i)*weights[i]^2
        if s²>0
          k = i+MSub*(l-1)
          denom[k] = weights[i]^2/(s²+λ)
          rowindex[k] = k
        end
      end
    end
  end

  denom, rowindex
end
