module nested_sampling_parallel_module
    implicit none

    integer,parameter :: flag_blank     = -2
    integer,parameter :: flag_gestating = -1
    integer,parameter :: flag_waiting   = 0

    contains

    !> Main subroutine for computing a generic nested sampling algorithm
    subroutine NestedSamplingP(loglikelihood,M,settings)
        use mpi_module
        use model_module,      only: model
        use utils_module,      only: logzero,loginf,DBL_FMT,read_resume_unit,stdout_unit
        use settings_module,   only: program_settings
        use utils_module,      only: logsumexp
        use read_write_module, only: write_resume_file,write_posterior_file
        use feedback_module

        implicit none

        interface
            function loglikelihood(theta,phi,context)
                double precision, intent(in),  dimension(:) :: theta
                double precision, intent(out),  dimension(:) :: phi
                integer,          intent(in)                 :: context
                double precision :: loglikelihood
            end function
        end interface

        type(model),            intent(in) :: M
        type(program_settings), intent(in) :: settings



        !> This is a very important array. live_data(:,i) constitutes the
        !! information in the ith live point in the unit hypercube:
        !! ( <-hypercube coordinates->, <-physical coordinates->, <-derived parameters->, likelihood)
        double precision, dimension(M%nTotal,settings%nstack) :: live_data
        double precision, allocatable, dimension(:,:)        :: live_data_local

        integer :: daughter_index
        integer :: mother_index(1)

        integer :: nprocs
        integer :: myrank
        integer :: nlive_local

        integer :: last_wait

        integer :: i_live
        integer :: i_slaves

        integer, parameter :: RUNTAG=0
        integer, parameter :: ENDTAG=1

        integer, dimension(MPI_STATUS_SIZE) :: mpi_status

        logical :: sending
        logical, allocatable, dimension(:) :: waiting_slave

        double precision, allocatable, dimension(:,:) :: posterior_array
        double precision, dimension(M%nDims+M%nDerived+2) :: posterior_point
        integer :: nposterior
        integer :: insertion_index(1)
        integer :: late_index(1)

        logical :: more_samples_needed

        ! The new-born baby point
        double precision,    dimension(M%nTotal)   :: baby_point
        double precision                           :: baby_likelihood

        ! The recently dead point
        double precision,    dimension(M%nTotal)   :: late_point
        double precision                           :: late_likelihood
        double precision :: late_logweight

        ! Point to seed a new one from
        double precision,    dimension(M%nTotal)   :: seed_point


        ! Evidence info
        double precision, dimension(6)             :: evidence_vec


        logical :: resume=.false.
        ! Means to be calculated
        double precision                           :: mean_likelihood_calls
        integer                                    :: total_likelihood_calls

        integer :: ndead

        double precision :: lognlive 
        double precision :: lognlivep1 
        double precision :: logminimumweight



        nprocs = mpi_size()  ! Get the number of MPI procedures
        myrank = mpi_rank()  ! Get the MPI label of the current processor

        if(myrank==0) call write_opening_statement(M,settings)

        ! Check to see whether there's a resume file present, and record in the
        ! variable 'resume'
        inquire(file=trim(settings%file_root)//'.resume',exist=resume)

        ! Check if we actually want to resume
        resume = settings%read_resume .and. resume

        if(resume .and. settings%feedback>=0 .and. myrank==0 ) write(stdout_unit,'("Resuming from previous run")')


        !======= 1) Initialisation =====================================
        ! (i)   On all nodes generate initial live points in parallel by sampling
        !       randomly from the prior (i.e. unit hypercube)
        ! (ii)  Initialise all variables for the master node
        ! (iii) Send out the first nprocs-1 tasks to the slaves

        !~~~ (i) Generate Live Points ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        if(resume) then
            if(myrank==0) then
                ! If there is a resume file present, then load the live points from that
                open(read_resume_unit,file=trim(settings%file_root)//'.resume',action='read')
                ! Read the live data
                read(read_resume_unit,'(<M%nTotal>E<DBL_FMT(1)>.<DBL_FMT(2)>)') live_data
                ! Cancel any points that were recorded as gestating
                do i_live = 1,settings%nstack
                    if( nint(live_data(M%daughter,i_live))==flag_gestating ) then
                        ! abort the gestating point
                        live_data(:,i_live) = blank_point(M)
                        ! find the mother and make her childless
                        mother_index = minloc(live_data(M%daughter,:),mask = nint(live_data(M%daughter,:))==i_live)
                        live_data(M%daughter,mother_index(1)) = flag_waiting
                    end if
                end do
            end if
        else !(not resume)
            if(myrank==0) call write_started_generating(settings%feedback)

            ! Initialise


            ! Otherwise generate them anew:
            ! Create initial live points on all processors, and then merge them onto
            ! the root with MPI_GATHER


            ! First allocate a local live_data array which is nlive/nprocs on each
            ! of the nprocs nodes
            nlive_local = ceiling(settings%nlive/(nprocs+0d0))
            allocate(live_data_local(M%nTotal,nlive_local))

            ! Generate nlive/nprocs live points on each of the nprocs nodes
            live_data_local = GenerateLivePoints(loglikelihood,M,nlive_local)

            ! Gather all of this data onto the root node
            call MPI_GATHER(          &  
                live_data_local,      & ! sending array
                M%nTotal*nlive_local, & ! number of elements to be sent
                MPI_DOUBLE_PRECISION, & ! type of element to be sent
                live_data,            & ! recieving array
                M%nTotal*nlive_local, & ! number of elements to be recieved from each node
                MPI_DOUBLE_PRECISION, & ! type of element recieved
                0,                    & ! root node address
                MPI_COMM_WORLD,       & ! communication info
                mpierror)               ! error (from module mpi_module)

            ! deallocate the now unused local live points array to save memory
            deallocate(live_data_local)

            do i_live=settings%nlive+1,settings%nstack
                live_data(:,i_live) = blank_point(M)
            end do


            if(myrank==0) call write_finished_generating(settings%feedback) !Flag to note that we're done generating 
        end if !(resume)



        !~~~ (ii) Initialise all variables on master node ~~~~~~~~~~~~~~
        ! There are several variables used throughout the rest of the
        ! algorithm that need to be initialised here
        !  (a) evidence_vec           | Vector containing the evidence, its error, and any other 
        !                             |  things that need to be accumulated over the run.
        !                             |  we need to initialise its sixth argument.
        !  (b) mean_likelihood_calls  | Mean number of likelihood calls over the past nlive iterations
        !  (c) ndead                  | Number of iterations/number of dead points
        !  (d) posterior_array        | Array of weighted posterior points

        if(myrank==0) then 

            ! (a) 
            if(resume) then
                ! If resuming, get the accumulated stats to calculate the
                ! evidence from the resume file
                read(read_resume_unit,'(6E<DBL_FMT(1)>.<DBL_FMT(2)>)') evidence_vec
            else !(not resume) 
                ! Otherwise compute the average loglikelihood and initialise the evidence vector accordingly
                evidence_vec = logzero
                evidence_vec(6) = logsumexp(live_data(M%l0,:)) - log(settings%nlive+0d0)
            end if !(resume) 

            ! (b) get number of dead points
            if(resume) then
                ! If resuming, then get the number of dead points from the resume file
                read(read_resume_unit,'(I)') ndead
            else !(not resume) 
                ! Otherwise no dead points originally
                ndead = 0
            end if !(resume) 

            ! (c) initialise the mean and total number of likelihood calls
            if(resume) then
                ! If resuming, then get the mean likelihood calls from the resume file
                read(read_resume_unit,'(E<DBL_FMT(1)>.<DBL_FMT(2)>)') mean_likelihood_calls
                ! Also get the total likelihood calls
                read(read_resume_unit,'(I)') total_likelihood_calls
            else
                mean_likelihood_calls = 1d0
                total_likelihood_calls = settings%nlive
            end if


            ! (d) Posterior array

            allocate(posterior_array(M%nDims+M%nDerived+2,settings%nmax_posterior))
            nposterior = 0
            ! set all of the loglikelihoods and logweights to be zero initially
            posterior_array(1:2,:) = logzero

            ! set the posterior coordinates to be zero initially
            posterior_array(3:,:) = 0d0

            if(resume) then
                ! Read the actual number we've used so far
                read(read_resume_unit,'(I)') nposterior
                !...followed by the posterior array itself
                read(read_resume_unit,'(<M%nDims+M%nDerived+2>E<DBL_FMT(1)>.<DBL_FMT(2)>)') posterior_array(:,:nposterior)
            end if !(resume) 

            ! Close the resume file if we've openend it
            if(resume) close(read_resume_unit)

            ! Calculate these global variables so we don't need to again
            lognlive   = log(settings%nlive+0d0)
            lognlivep1 = log(settings%nlive+1d0)
            logminimumweight = log(settings%minimum_weight)


            allocate(waiting_slave(nprocs-1))
            waiting_slave = .false.

            last_wait = -1


        end if

        ! Write a resume file before we start
        if(myrank==0 .and. settings%write_resume) call write_resume_file(settings,M,live_data,evidence_vec,ndead,mean_likelihood_calls,total_likelihood_calls,nposterior,posterior_array)  



        !~~~ (iii) Send out first tasks ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        ! We hand over the first nprocs-1 jobs from the master to the slaves
        ! Note that this is slightly less involved than the manner in which we
        ! hand out tasks later, since these tasks are handed out in sequential
        ! order
        if(myrank==0) then
            do i_slaves=1,nprocs-1

                ! Generate a seed point from live_data, and update accordingly
                seed_point = GenerateSeed(M,settings%nstack,live_data)

                ! If it's a 'blank' seed then we need to wait until a
                ! good seed can be generated
                if(nint(seed_point(M%daughter))==flag_blank) then
                    write(stdout_unit,'(" Error: nprocs =", I8, " is too large for nlive = ", I8)') nprocs, settings%nlive
                    call abort()

                    return
                end if


                ! Send a seed point to the i_slaves th slave
                call MPI_SEND(            &
                    seed_point,           & ! seed point to be sent
                    M%nTotal,             & ! size of this data
                    MPI_DOUBLE_PRECISION, & ! type of this data
                    i_slaves,             & ! send it to the i_slaves point
                    RUNTAG,               & ! tagging information (not important here)
                    MPI_COMM_WORLD,       & ! communication data
                    mpierror              & ! error information (from mpi_module)
                    )
            end do

        end if




        !======= 2) Main loop body =====================================
        !
        ! This parallelised by splitting it into two parts: Master and Slaves
        !
        ! The slaves take the job of generating new points from seed points
        ! (within a given likelihood contour)
        !
        ! The master's job is to collate the newly generated points into the
        ! live points array and to calculate evidence

        if(myrank ==0) call write_started_sampling(settings%feedback)

        ! definitely more samples needed than this
        more_samples_needed = .true.

        do while ( more_samples_needed )

            if(myrank == 0) then
                
                !================================================================
                !===================== MASTER NODE ==============================
                !================================================================
                !
                ! (1) Keep track of the lowest loglikelihood contour that hasn't
                !      yet been sent off for sampling (loglikelihood_bound)
                !
                ! (2) Recieve baby point from any slave, along with the contour
                !      it was generated from and insert it into the stack
                !
                ! (3) Send new seed to the now waiting slave. This seed is drawn 
                !      from the set of live points with a likelihood greater
                !      than loglikelihood_bound
                !
                ! (4) Update the live points by birthing any points that are now
                !      ready from the stack



                do i_slaves=1,nprocs-1

                    ! Listen for any sending nodes
                    call MPI_IPROBE(    &  
                        i_slaves,       & !
                        MPI_ANY_TAG,    & !
                        MPI_COMM_WORLD, & !
                        sending,        & !
                        mpi_status,     & !
                        mpierror        & !
                        )

                    if (sending) then

                        ! (2) Recieve newly generated baby point from any slave
                        !
                        call MPI_RECV(            &
                            baby_point,           & ! newly generated point to be receieved
                            M%nTotal,             & ! size of this data
                            MPI_DOUBLE_PRECISION, & ! type of this data
                            i_slaves,             & ! recieve it from any slave
                            MPI_ANY_TAG,          & ! tagging information (not important here)
                            MPI_COMM_WORLD,       & ! communication data
                            mpi_status,           & ! status - important (tells you where it's been recieved from )
                            mpierror              & ! error information (from mpi_module)
                            )

                        ! (2) Insert into incubator
                        !
                        ! get the place in the stack for this point
                        daughter_index = nint(baby_point(M%daughter))
                        ! note that this point hasn't launched any new ones
                        baby_point(M%daughter)=flag_waiting
                        ! Insert this into the stack
                        live_data(:,daughter_index) = baby_point

                        ! Mark this node as waiting for a new point
                        waiting_slave(i_slaves) = .true.

                    end if
                end do

                ! Kill any lowest points with daughters waiting to take their
                ! place
                do while(.true.)
                    ! Find the point with the lowest likelihood...
                    late_index = minloc(live_data(M%l0,:),mask=live_data(M%daughter,:)>=flag_waiting)

                    ! If there is no such point, then all live points are gestating
                    if(late_index(1)==0) exit

                    ! ...and save it.
                    late_point = live_data(:,late_index(1))
                    ! Get the likelihood contour
                    late_likelihood = late_point(M%l0)
                    ! Calculate the late logweight
                    late_logweight = (ndead-1)*lognlive - ndead*lognlivep1 

                    ! Find the position of the daughter of the late point
                    daughter_index  = nint( late_point(M%daughter) )

                    ! Check to see if the late point has a daughter
                    if(daughter_index<=flag_waiting) exit

                    ! Check to see if that daughter has been born yet
                    if(live_data( M%daughter, daughter_index )<=flag_gestating ) exit

                    ! Kill the late point
                    live_data(:,late_index(1)) = blank_point(M)

                    ! Promote the daughter to a live point
                    baby_point = live_data(:,daughter_index) 
                    baby_likelihood  = baby_point(M%l0)

                    ! record that we have a new dead point
                    ndead = ndead + 1

                    ! If we've put a limit on the maximum number of iterations, then
                    ! check to see if we've reached this
                    if (settings%max_ndead >0 .and. ndead .ge. settings%max_ndead) more_samples_needed = .false.

                    ! (4) Calculate the new evidence (and check to see if we're accurate enough)
                    call settings%evidence_calculator(baby_likelihood,late_likelihood,ndead,more_samples_needed,evidence_vec)




                    ! (5) Update the set of weighted posteriors
                    if( settings%calculate_posterior .and. late_point(M%l0) + late_logweight - evidence_vec(1) > logminimumweight ) then
                        ! If the late point has a sufficiently large weighting, then we
                        ! should add it to the set of saved posterior points

                        ! calculate a new point for insertion
                        posterior_point(1)  = late_point(M%l0) + late_logweight
                        posterior_point(2)  = late_point(M%l0)
                        posterior_point(3:3+M%nDims-1) = late_point(M%p0:M%p1)
                        posterior_point(4+M%nDims:4+M%nDerived-1) = late_point(M%d0:M%d1)

                        if(nposterior<settings%nmax_posterior) then
                            ! If we're still able to use a restricted array,

                            ! Find the closest point in the array which is beneath the minimum weight
                            insertion_index = minloc(posterior_array(1,:nposterior),mask=posterior_array(1,:nposterior)<logminimumweight+evidence_vec(1))

                            if(insertion_index(1)==0) then
                                ! If there are no points to overwrite, then we should
                                ! expand the available storage array
                                nposterior=nposterior+1
                                posterior_array(:,nposterior) = posterior_point
                            else
                                ! Otherwise overwrite the 
                                posterior_array(:,insertion_index(1)) = posterior_point
                            end if

                        else
                            ! Otherwise we have to overwrite the smallest element
                            insertion_index = minloc(posterior_array(1,:nposterior))
                            posterior_array(:,insertion_index(1)) = posterior_point
                        end if

                    end if


                    ! (6) Command line feedback

                    ! update the mean number of likelihood calls
                    mean_likelihood_calls = mean_likelihood_calls + (baby_point(M%nlike) - late_point(M%nlike) ) / (settings%nlive + 0d0)

                    ! update the total number of likelihood calls
                    total_likelihood_calls = total_likelihood_calls + baby_point(M%nlike)


                    ! Feedback to command line every nlive iterations
                    if (settings%feedback>=1 .and. mod(ndead,settings%nlive) .eq.0 ) then
                        write(stdout_unit,'("ndead     = ", I20                  )') ndead
                        write(stdout_unit,'("efficiency= ", F20.2                )') mean_likelihood_calls
                        write(stdout_unit,'("log(Z)    = ", F20.5, " +/- ", F12.5)') evidence_vec(1), exp(0.5*evidence_vec(2)-evidence_vec(1)) 
                        write(stdout_unit,'("")')
                    end if

                    ! (7) Update the resume and posterior files every update_resume iterations, or at program termination
                    if (mod(ndead,settings%update_resume) .eq. 0 .or.  more_samples_needed==.false.)  then
                        if(settings%write_resume) call write_resume_file(settings,M,live_data,evidence_vec,ndead,mean_likelihood_calls,total_likelihood_calls,nposterior,posterior_array)  
                        if(settings%calculate_posterior) call write_posterior_file(settings,M,posterior_array,evidence_vec(1),nposterior)  
                    end if

                end do




                slave_loop: do i_slaves=1,nprocs-1
                    if( waiting_slave(i_slaves) ) then

                        ! Generate a seed point from live_data, and update accordingly
                        seed_point = GenerateSeed(M,settings%nstack,live_data) 

                        ! If it's a 'blank' seed then we need to wait until a
                        ! good seed can be generated
                        if(nint(seed_point(M%daughter))==flag_blank) then
                            if(last_wait>ndead) write(stdout_unit,'(" Warning: no valid seeds at ndead =", I8 " - Consider reducing nprocs to avoid CPU waste")') ndead
                            last_wait = ndead
                            exit slave_loop
                        end if

                        ! Send a seed point back to that slave
                        call MPI_SEND(              &
                            seed_point,             & ! seed point to be sent
                            M%nTotal,               & ! size of this data
                            MPI_DOUBLE_PRECISION,   & ! type of this data
                            i_slaves,               & ! send it to the point we just recieved from
                            RUNTAG,                 & ! tagging information (not important here)
                            MPI_COMM_WORLD,         & ! communication data
                            mpierror                & ! error information (from mpi_module)
                            )

                        waiting_slave(i_slaves)=.false.
                    end if
                end do slave_loop



            else
                !================================================================
                !===================== SLAVE NODES ==============================
                !================================================================

                ! Listen for a signal from the master
                call MPI_RECV(            &
                    seed_point,           & ! seed point to be recieved
                    M%nTotal,             & ! size of this data
                    MPI_DOUBLE_PRECISION, & ! type of this data
                    0,                    & ! recieve it from the master
                    MPI_ANY_TAG,          & ! recieve any tagging information
                    MPI_COMM_WORLD,       & ! communication data
                    mpi_status,           & ! status (not important here)
                    mpierror              & ! error information (from mpi_module)
                    )

                ! If we receive a kill signal, then exit the loop
                if(mpi_status(MPI_TAG)==ENDTAG) then
                    more_samples_needed=.false.
                    exit
                end if

                ! Calculate a new baby point from the seed point
                baby_point = settings%sampler(loglikelihood,seed_point, M)

                ! Send the baby point back
                call MPI_SEND(            &
                    baby_point,           & ! baby point to be sent
                    M%nTotal,             & ! size of this data
                    MPI_DOUBLE_PRECISION, & ! type of this data
                    0,                    & ! send it to the master
                    RUNTAG,               & ! tagging information (not important here)
                    MPI_COMM_WORLD,       & ! communication data
                    mpierror              & ! error information (from mpi_module)
                    )

            end if
            
        end do ! End main loop



        if (myrank==0) then
            
            ! If we're done, then clean up by receiving the last piece of
            ! data from each node (and throw it away) and then send a kill signal back to it
            if(more_samples_needed==.false.) then
                do i_slaves=1,nprocs-1
                    if( .not. waiting_slave(i_slaves) ) then
                        call MPI_RECV(            &
                            baby_point,           & ! newly generated point to be receieved
                            M%nTotal,             & ! size of this data
                            MPI_DOUBLE_PRECISION, & ! type of this data
                            i_slaves,             & ! recieve it from any slave
                            MPI_ANY_TAG,          & ! tagging information (not important here)
                            MPI_COMM_WORLD,       & ! communication data
                            mpi_status,           & ! status - important (tells you where it's been recieved from )
                            mpierror              & ! error information (from mpi_module)
                            )
                    end if
                    call MPI_SEND(              &
                        seed_point,             & ! seed point to be sent
                        M%nTotal,               & ! size of this data
                        MPI_DOUBLE_PRECISION,   & ! type of this data
                        i_slaves,               & ! send it to the point we just recieved from
                        ENDTAG,                 & ! tagging information (not important here)
                        MPI_COMM_WORLD,         & ! communication data
                        mpierror                & ! error information (from mpi_module)
                        )
                end do


            end if




            call write_final_results(M,evidence_vec,ndead,total_likelihood_calls,settings%feedback)  
        end if

    end subroutine NestedSamplingP




    !> Generate an initial set of live points distributed uniformly in the unit hypercube
    function GenerateLivePoints(loglikelihood,M,nlive) result(live_data)
        use model_module,    only: model, calculate_point
        use random_module,   only: random_reals
        use utils_module,    only: logzero

        implicit none
        
        interface
            function loglikelihood(theta,phi,context)
                double precision, intent(in),  dimension(:) :: theta
                double precision, intent(out),  dimension(:) :: phi
                integer,          intent(in)                 :: context
                double precision :: loglikelihood
            end function
        end interface

        !> The model details (loglikelihood, priors, ndims etc...)
        type(model), intent(in) :: M

        !> The number of points to be generated
        integer, intent(in) :: nlive

        !live_data(:,i) constitutes the information in the ith live point in the unit hypercube: 
        ! ( <-hypercube coordinates->, <-derived parameters->, likelihood)
        double precision, dimension(M%nTotal,nlive) :: live_data

        ! Loop variable
        integer i_live

        ! initialise live points at zero
        live_data = 0d0

        do i_live=1,nlive

            ! Generate a random coordinate
            live_data(:,i_live) = random_reals(M%nDims)

            ! Compute physical coordinates, likelihoods and derived parameters
            call calculate_point(loglikelihood, M, live_data(:,i_live) )

        end do

        ! Set the number of likelihood calls for each point to 1
        live_data(M%nlike,:) = 1

        ! Set the initial trial values of the chords as the diagonal of the hypercube
        live_data(M%last_chord,:) = sqrt(M%nDims+0d0)

        ! Initially, none of the points have been calculated yet
        live_data(M%daughter,:) = flag_waiting

        ! Set the likelihood contours to logzero for now
        live_data(M%l1,:) = logzero


    end function GenerateLivePoints



    function GenerateSeed(M,nstack,live_data) result(seed_point)
        use model_module,      only: model
        use random_module,     only: random_integer
        implicit none
        type(model),      intent(in) :: M
        integer, intent(in) :: nstack
        double precision, intent(inout), dimension(M%nTotal,nstack) :: live_data

        ! Point to seed a new one from
        double precision,    dimension(M%nTotal)   :: seed_point


        integer :: counter
        integer :: daughter_index(1)
        integer :: live_index(1)

        double precision :: loglikelihood_bound

        ! Find the lowest likelihood point whose contour is waiting to
        ! be generated from                  
        live_index = minloc(live_data(M%l0,:),mask=nint(live_data(M%daughter,:))==flag_waiting) 
        if(live_index(1)==0) then
            seed_point = blank_point(M)
            return
        end if

        ! Find a place stack for the generated point
        ! We search through the stack to find the first index which indicates
        ! the point is 'blank'
        daughter_index = minloc(live_data(M%daughter,:),mask=nint(live_data(M%daughter,:))==flag_blank) 
        if(daughter_index(1)==0) then
            seed_point = blank_point(M)
            return
        end if

        ! Give this place to the point that generated the contour
        live_data(M%daughter,live_index(1)) = daughter_index(1)

        ! Note at the daughter's place that we're waiting on a
        ! point to be generated
        live_data(M%daughter,daughter_index(1))=flag_gestating
             
        ! Select a seed point for the generator
        !  -excluding the points which have likelihoods equal to the
        !   loglikelihood bound
        !  -as well as those which were generated with a likelihood less than
        !   the loglikelihood bound
        loglikelihood_bound = live_data(M%l0,live_index(1))
        seed_point(M%l0)=loglikelihood_bound

        counter = 0
        do while (seed_point(M%l0)<=loglikelihood_bound .or. seed_point(M%l1)>loglikelihood_bound .or. nint(seed_point(M%daughter))==flag_blank )
            ! get a random integer in [1,nstack]
            ! get this point from live_data 
            seed_point = live_data(:,random_integer(nstack))
            counter = counter+1
            if(counter>nstack*10) then
                seed_point=blank_point(M)
                return
            end if
        end do

        ! Record the likelihood bound which this seed will generate from
        seed_point(M%l1) = loglikelihood_bound

        ! Record the eventual position in the stack
        seed_point(M%daughter) = daughter_index(1)

    end function GenerateSeed

    function blank_point(M)
        use utils_module, only: logzero,loginf
        use model_module, only: model
        implicit none
        type(model),            intent(in) :: M
        double precision, dimension(M%nTotal) :: blank_point

            blank_point = 0d0
            blank_point(M%daughter) = flag_blank
            blank_point(M%l0) = logzero
            blank_point(M%l1) = logzero
            blank_point(M%nlike) = 0d0
            blank_point(M%last_chord) = 0d0

    end function blank_point




end module nested_sampling_parallel_module