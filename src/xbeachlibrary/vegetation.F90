!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Copyright (C) 2011 UNESCO-IHE, WL|Delft Hydraulics and Delft University !
! Dano Roelvink, Ap van Dongeren, Ad Reniers, Jamie Lescinski,            !
! Jaap van Thiel de Vries, Robert McCall                                  !
!                                                                         !
! d.roelvink@unesco-ihe.org                                               !
! UNESCO-IHE Institute for Water Education                                !
! P.O. Box 3015                                                           !
! 2601 DA Delft                                                           !
! The Netherlands                                                         !
!                                                                         !
! This library is free software; you can redistribute it and/or           !
! modify it under the terms of the GNU Lesser General Public              !
! License as published by the Free Software Foundation; either            !
! version 2.1 of the License, or (at your option) any later version.      !
!                                                                         !
! This library is distributed in the hope that it will be useful,         !
! but WITHOUT ANY WARRANTY; without even the implied warranty of          !
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU        !
! Lesser General Public License for more details.                         !
!                                                                         !
! You should have received a copy of the GNU Lesser General Public        !
! License along with this library; if not, write to the Free Software     !
! Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307     !
! USA                                                                     !
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! VEGETATION MODULE XBEACH: ATTENUATION OF SHORT WAVES, IG WAVES, FLOW, AND WAVE SETUP
! 
! Version 1.0: 
! Attenuation of short waves and IG waves 
! Jaap van Thiel de Vries, okt 2013, 
! see Linh K. Phan, Jaap S.M. van Thiel de Vries, and Marcel J.F. Stive (2015) Coastal Mangrove Squeeze in the Mekong Delta. Journal of Coastal Research: Volume 31, Issue 2: pp. 233 � 243.
! 
! Version 2.0: 
! Attenuation of short waves, IG waves and nonlinear wave effects 
! Arnold van Rooijen, okt 2015, 
! see Van Rooijen, McCall, Van Thiel de Vries, Van Dongeren, Reniers and Roelvink (2016), Modeling the effect of wave-vegetation interaction on wave setup, JGR Oceans 121, pp 4341-4359.
!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

module vegetation_module
    use typesandkinds
    implicit none
    save

    type veggie
        character(slen)                         :: name        ! Name of vegetation specification file
        integer                                 :: nsec        ! Number of sections used in vertical schematization of vegetation [-]
        real*8  , dimension(:)    , allocatable :: ah          ! Height of vertical sections used in vegetation schematization [m wrt zb_ini (zb0)]
        real*8  , dimension(:)    , allocatable :: Cd          ! Bulk drag coefficient [-]
        real*8  , dimension(:)    , allocatable :: bv          ! Width/diameter of individual vegetation stems [m]
        integer , dimension(:)    , allocatable :: N           ! Number of vegetation stems per unit horizontal area [m-2]
    end type veggie

    public veggie_init
    public vegatt
    public porcanflow ! porous in-canopy model
   
contains

subroutine veggie_init(s,par)
    use params
    use xmpi_module    
    use spaceparams
    use readkey_module
    use filefunctions
    use logging_module
    use interp

    IMPLICIT NONE

    type(parameters)                            :: par
    type(spacepars), target                     :: s
    
    !character(1)                                :: ch
    type(veggie), dimension(:), allocatable     :: veg
    integer                                     :: i,j,fid,ier,is,m,ind
    
    if (par%vegetation == 1) then
        ! INITIALIZATION OF VEGETATION
        ! Read files with vegetation properties:
        ! file 1: list of species
        ! file 2: vegetation properties per specie (could be multiple files)
        ! file 3: distribution of species over space
        call writelog('l','','--------------------------------')
        call writelog('l','','Initializing vegetation input settings ')

        ! 1) Read veggiefile with veggie species
        par%nveg = count_lines(par%veggiefile)

        if (xmaster) then
            allocate(veg(par%nveg))          
            fid=create_new_fid()
            call check_file_exist(par%veggiefile)
            open(fid,file=par%veggiefile)
            do i=1,par%nveg
                read(fid,'(a)',iostat=ier) veg(i)%name
            enddo
            close(fid)

            allocate(s%vegtype(par%nx+1, par%ny+1))
            allocate(s%Dveg(par%nx+1, par%ny+1))
            allocate(s%Fvegu(par%nx+1, par%ny+1))
            allocate(s%Fvegv(par%nx+1, par%ny+1))
            allocate(s%ucan(par%nx+1, par%ny+1))
            allocate(s%vcan(par%nx+1, par%ny+1))
            
            s%vegtype = 0
            s%Cdveg   = 0.d0
            s%ahveg   = 0.d0
            s%bveg    = 0.d0
            s%Nveg    = 0.d0
            s%Dveg    = 0.d0
            s%Fvegu   = 0.d0
            s%Fvegv   = 0.d0
            s%ucan    = 0.d0
            s%vcan    = 0.d0
            s%nsecvegmax = 1
    
            ! 2)  Read spatial distribution of all vegetation species 
            ! NB: vegtype = 1 corresponds to first vegetation specified in veggiefile etc.
            fid=create_new_fid() ! see filefunctions.F90
            call check_file_exist(par%veggiemapfile)
          
            select case(par%gridform)
                case(GRIDFORM_XBEACH)
                    open(fid,file=par%veggiemapfile)
                        do j=1,s%ny+1
                            read(fid,*,iostat=ier)(s%vegtype(i,j),i=1,s%nx+1)
                            if (ier .ne. 0) then
                                call report_file_read_error(par%veggiemapfile)
                            endif
                        enddo
                    close(fid)
                case (GRIDFORM_DELFT3D)
                    open(fid,file=par%veggiemapfile,status='old')
                        do j=1,s%ny+1
                            read(fid,*,iostat=ier)(s%vegtype(i,j),i=1,s%nx+1)
                            if (ier .ne. 0) then
                                call report_file_read_error(par%veggiemapfile)
                            endif
                        enddo
                    close(fid)
            end select
   
            ! 3)  Allocate and read vegetation properties for every species    
            do is=1,par%nveg  ! for each species
                call check_file_exist(veg(is)%name)
                veg(is)%nsec    = readkey_int(veg(is)%name,'nsec',  1,        1,      100, silent=.true., bcast=.false.)
                ! Number of vertical sections in vegetation schematization (max = 100)
       
                allocate (veg(is)%ah(veg(is)%nsec))
                allocate (veg(is)%Cd(veg(is)%nsec))
                allocate (veg(is)%bv(veg(is)%nsec))
                allocate (veg(is)%N(veg(is)%nsec))
        
                veg(is)%ah   =      readkey_dblvec(veg(is)%name,'ah',veg(is)%nsec,size(veg(is)%ah), 0.1d0,   0.01d0,     2.d0, bcast=.false. )
                veg(is)%bv   =      readkey_dblvec(veg(is)%name,'bv',veg(is)%nsec,size(veg(is)%bv), 0.01d0, 0.001d0,    1.0d0, bcast=.false. )       
                veg(is)%N    = nint(readkey_dblvec(veg(is)%name,'N', veg(is)%nsec,size(veg(is)%N) ,100.0d0,   1.0d0,  5000.d0, bcast=.false. ))        
                veg(is)%Cd   =      readkey_dblvec(veg(is)%name,'Cd',veg(is)%nsec,size(veg(is)%Cd),  0.0d0,  0.0d0,      3d0, bcast=.false. ) 
                
                ! Get maximum number of vegetation sections within model domain - needed to set size of Cd, ah, bv and Nv matrix
                s%nsecvegmax = max(s%nsecvegmax, veg(is)%nsec)                               
            enddo
            
            ! Create spatially varying nsec, ah, bv, N and Cd within s-structure
            allocate(s%nsecveg(par%nx+1, par%ny+1))
            allocate(s%Cdveg(par%nx+1, par%ny+1, s%nsecvegmax))
            allocate(s%ahveg(par%nx+1, par%ny+1, s%nsecvegmax))
            allocate(s%bveg(par%nx+1, par%ny+1,  s%nsecvegmax))
            allocate(s%Nveg(par%nx+1, par%ny+1,  s%nsecvegmax))
                    
            do j = 1,s%ny+1
                do i = 1,s%nx+1
                    ind = s%vegtype(i,j)                   
                    if (ind > 0) then ! set vegetation properties at locations where vegetation is present
                        s%nsecveg(i,j) = veg(ind)%nsec
                        do m=1,s%nsecveg(i,j)
                            s%Cdveg(i,j,m) = veg(ind)%Cd(m)
                            s%ahveg(i,j,m) = veg(ind)%ah(m)
                            s%bveg(i,j,m)  = veg(ind)%bv(m)
                            s%Nveg(i,j,m)  = veg(ind)%N(m)
                        enddo
                    else ! set to zero at locations of no vegetation
                        s%nsecveg(i,j) = 0
                        s%Cdveg(i,j,:) = 0.d0
                        s%ahveg(i,j,:) = 0.d0
                        s%bveg(i,j,:)  = 0.d0
                        s%Nveg(i,j,:)  = 0.d0
                    endif
                enddo
            enddo
            deallocate(veg)
        endif
       
        call writelog('l','','--------------------------------')
        call writelog('l','','Finished reading vegetation input... ')

    else ! par%vegetation == 0
       if (xmaster) then
          ! just allocate address for memory, only on xmaster, rest is
          ! done automatically by call from libxbeach
          allocate(s%vegtype(par%nx+1, par%ny+1))
          allocate(s%nsecveg(par%nx+1, par%ny+1))
          allocate(s%Cdveg(par%nx+1, par%ny+1, 1))
          allocate(s%ahveg(par%nx+1, par%ny+1, 1))
          allocate(s%bveg(par%nx+1, par%ny+1, 1))
          allocate(s%Nveg(par%nx+1, par%ny+1, 1))
          allocate(s%Dveg(par%nx+1, par%ny+1))
          allocate(s%Fvegu(par%nx+1, par%ny+1))
          allocate(s%Fvegv(par%nx+1, par%ny+1))
          allocate(s%ucan(par%nx+1, par%ny+1))
          allocate(s%vcan(par%nx+1, par%ny+1))
          s%vegtype = 0
          s%nsecveg = 0
          s%nsecvegmax = 1
          s%Cdveg = 0.d0
          s%ahveg = 0.d0
          s%bveg = 0.d0
          s%Nveg = 0.d0
          s%Dveg = 0.d0
          s%Fvegu = 0.d0
          s%Fvegv = 0.d0
          s%ucan = 0.d0
          s%vcan = 0.d0
       endif
    endif
end subroutine veggie_init

subroutine vegatt(s,par)
    use params
    use spaceparams
    use readkey_module
    use xmpi_module
    use filefunctions
    use interp
    use logging_module

    type(parameters)                            :: par
    type(spacepars)                             :: s

    ! local variables
    integer                                     :: i,j,m
    real*8                                      :: Cdterm

    ! Skip in case of using porous in-canopy model
    if (par%porcanflow == 1) then
        call porcanflow(s,par)
        return
    endif
    
    ! First compute drag coefficient (if not user-defined)
    do j=1,s%ny+1
        do i=1,s%nx+1
            if (s%nsecveg(i,j) > 0) then ! only in case vegetation is present
                do m=1,s%nsecveg(i,j) ! for each vertical vegetation section
                    if (s%Cdveg(i,j,m) < 0.d0) then ! If Cd is not user specified: call subroutine of M. Bendoni
                        call bulkdragcoeff(s,par,s%ahveg(i,j,m)+s%zb0(i,j)-s%zb(i,j),m,i,j,Cdterm)
                        s%Cdveg(i,j,m) = Cdterm
                    endif
                enddo
            endif
        enddo
    enddo
                
    ! Attenuation by vegetation is computed in wave action balance (swvegatt) and the momentum balance (momeqveg); 
    !
    ! 1) Short wave dissipation by vegetation
    call swvegatt(s,par)

    ! 2) Mom.Eq.: Long wave dissipation, mean flow dissipation, nonlinear short wave effects, effect of emerged vegetation
    call momeqveg(s,par)

end subroutine vegatt

subroutine swvegatt(s,par)
    use params
    use spaceparams
    use readkey_module
    use filefunctions
    use interp

    type(parameters)                            :: par
    type(spacepars), target                     :: s
    !type(veggie), dimension(:), pointer         :: veg
    
    ! local variables
    integer                                     :: i,j,m  ! indices of actual x,y point
    real*8                                      :: aht,hterm,htermold,Dvgt,ahtold
    real*8, dimension(s%nx+1,s%ny+1)            :: Dvg,kmr

    !include 's.ind'
    !include 's.inp'

    kmr = min(max(s%k, 0.01d0), 100.d0)

    ! Set dissipation in vegetation to zero everywhere for a start
    Dvg = 0.d0
    do j=1,s%ny+1
        do i=1,s%nx+1
            htermold = 0.d0
            ahtold = 0.d0
            if (s%nsecveg(i,j)>0) then ! only if vegetation is present at (i,j)
                do m=1,s%nsecveg(i,j)
             
                    ! Determine height of vegetation section (restricted to current bed level)
                    !aht = veg(ind)%ah(m)+ahtold !+s%zb0(i,j)-s%zb(i,j)!(max(veg(ind)%zv(m)+s%zb0(i,j),s%zb(i,j)))
                    aht = s%ahveg(i,j,m)+ahtold
                    
                    ! restrict vegetation height to local water depth
                    aht = min(aht,s%hh(i,j))
             
                    ! compute hterm based on ah
                    hterm = (sinh(kmr(i,j)*aht)**3+3*sinh(kmr(i,j)*aht))/(3.d0*kmr(i,j)*cosh(kmr(i,j)*s%hh(i,j))**3)
             
                    ! compute dissipation based on aht and correct for lower elevated dissipation layers (following Suzuki et al. 2012)
                    Dvgt = 0.5d0/sqrt(par%px)*par%rho*s%Cdveg(i,j,m)*s%bveg(i,j,m)*s%Nveg(i,j,m)*(0.5d0*kmr(i,j)*par%g/s%sigm(i,j))**3*(hterm-htermold)*s%H(i,j)**3
                    
                    ! save hterm to htermold to correct possibly in next vegetation section
                    htermold = hterm
                    ahtold   = aht
             
                    ! add dissipation current vegetation section
                    Dvg(i,j) = Dvg(i,j) + Dvgt
                enddo
            endif
        enddo
    enddo
    s%Dveg = Dvg

end subroutine swvegatt

subroutine momeqveg(s,par)
    use params
    use spaceparams
    use readkey_module
    use filefunctions
    use interp

    type(parameters)                            :: par
    type(spacepars)                             :: s
    !type(veggie), dimension(:), pointer         :: veg
    
    ! local variables
    integer                                     :: i,j,m  ! indices of actual x,y point
    real*8                                      :: aht,ahtold,Fvgtu,Fvgtv,FvgStu,FvgStv,watr,wacr,uabsu,vabsv
    real*8                                      :: Fvgnlt,Fvgnlu,Fvgnlv,FvgCan,FvgCav,FvgCau,ucan,uabsunl !uabsunl,vabsvnl,hterm,htermold,
    real*8, dimension(s%nx+1,s%ny+1)            :: Fvgu,Fvgv,kmr
    real*8, save                                :: totT
    real*8, dimension(s%nx+1,s%ny+1,50)         :: unl0,etaw0
    real*8, save, allocatable, dimension(:,:,:) :: unl,etaw
    real*8, dimension(50)                       :: hvegeff,Fvgnlu0 
    real*8, dimension(:,:), allocatable,save    :: sinthm, costhm

    !include 's.ind'
    !include 's.inp'

    ! Compute one force related to vegetation present in the water column:
    ! 1) Long wave velocity (ul)
    ! 2) Stokes velocity (us)
    ! 3) Non linear short wave velocity residual (ua)
    ! 4) return flow / undertow (ue)
    ! 5) wave-induced in-canopy flow (?)
    
    ! only allocate in 1st timestep
    if (.not. allocated(sinthm)) then
        allocate (sinthm(s%nx+1,s%ny+1))
        allocate (costhm(s%nx+1,s%ny+1))
    endif
    kmr = min(max(s%k, 0.01d0), 100.d0)

    Fvgu = 0.d0
    Fvgv = 0.d0
    Fvgnlt = 0.d0
    Fvgnlu = 0.d0
    Fvgnlv = 0.d0
    FvgStu = 0.d0
    FvgStv = 0.d0
    ucan   = 0.d0
    FvgCan = 0.d0
    FvgCav = 0.d0
    FvgCau = 0.d0
    uabsunl = 0.d0
       
    costhm = cos(s%thetamean-s%alfaz)
    sinthm = sin(s%thetamean-s%alfaz)
    
    ! initialize totT
    if (par%dt == par%t) then
        totT = par%Trep
    endif    
    if (par%vegnonlin == 1 .and. par%wavemodel/=WAVEMODEL_NONH) then      
        ! only compute new nonlinear velocity profile every Trep s
        if(totT >= par%Trep) then     
            call swvegnonlin(s,par,unl0,etaw0)
            unl  = unl0
            etaw = etaw0
            totT = 0.d0
        else 
            totT = totT + par%dt
        endif
    endif
    
    do j=1,s%ny+1
        do i=1,s%nx+1
            ahtold = 0.d0
            if (s%nsecveg(i,j)>0) then ! Only if vegetation is present 
                  
                ! Compute uabsu for calculation of Fveg
                uabsu = 0.d0
                vabsv = 0.d0
                Fvgnlu0 = 0.d0
                        
                watr = 0d0
                wacr = 0d0
                do m=1,s%nsecveg(i,j)
                    ! Determine height of vegetation section (restricted to current bed level)
                    aht = s%ahveg(i,j,m)+s%zb0(i,j)-s%zb(i,j)
                
                    ! Determine which part of the vegetation is below the wave trough, and between trough and crest
                    if (par%vegnonlin == 1 .and. par%wavemodel/=WAVEMODEL_NONH) then
                        watr = minval(etaw(i,j,:))
                        watr = s%hh(i,j) + watr ! wave trough level
                        wacr = maxval(etaw(i,j,:))
                        wacr = s%hh(i,j) + wacr ! wave crest level
                    else
                        watr = s%hh(i,j)
                        wacr = s%hh(i,j)
                    endif

                    if (ahtold > wacr) then ! if plant section is entirely above wave crest, then do nothing
                      
                        ! mean and long wave flow (ue)                      
                        Fvgtu = 0d0
                        Fvgtv = 0d0
                    
                        ! nonlinear waves 
                        Fvgnlu = 0.d0
                        Fvgnlv = 0.d0
                      
                    else ! vegetation section is located (partly) in between wave trough and crest level                  
                        if (par%veguntow == 1) then
                            ! mean and long wave flow (ue, ve)
                            Fvgtu = max((min(aht,watr)-ahtold),0d0)*0.5d0*s%Cdveg(i,j,m)*s%bveg(i,j,m)*s%Nveg(i,j,m)*(s%ueu(i,j)*s%vmageu(i,j))
                            Fvgtv = max((min(aht,watr)-ahtold),0d0)*0.5d0*s%Cdveg(i,j,m)*s%bveg(i,j,m)*s%Nveg(i,j,m)*(s%vev(i,j)*s%vmageu(i,j))                       
                        else
                            ! Only long wave velocity (assume undertow is diverted over vegetation)
                            Fvgtu = max((min(aht,watr)-ahtold),0d0)*0.5d0*s%Cdveg(i,j,m)*s%bveg(i,j,m)*s%Nveg(i,j,m)*(s%uu(i,j)*s%vmagu(i,j))
                            Fvgtv = max((min(aht,watr)-ahtold),0d0)*0.5d0*s%Cdveg(i,j,m)*s%bveg(i,j,m)*s%Nveg(i,j,m)*(s%vv(i,j)*s%vmagu(i,j))
                        endif
                                                        
                        ! nonlinear waves (including emerged vegetation effect)
                        !etaw    = 0.d0
                        if (par%vegnonlin == 1 .and. par%wavemodel/=WAVEMODEL_NONH) then 
                            hvegeff = max(etaw(i,j,:) + s%hh(i,j)-ahtold,0.d0) ! effective vegetation height over a wave cycle
                            Fvgnlt  = trapz(((0.5d0*s%Cdveg(i,j,m)*s%bveg(i,j,m)*s%Nveg(i,j,m))*min(hvegeff,aht)*unl(i,j,:)*abs(unl(i,j,:))),par%Trep/50)/s%hh(i,j)
                        
                            ! decompose in u and v-direction
                            Fvgnlu  = Fvgnlt*costhm(i,j)
                            Fvgnlv  = Fvgnlt*sinthm(i,j)
                        endif
                    
                        ! wave induced incanopy flow (Luhar et al., 2010)
                        ucan   = sqrt(4.d0*kmr(i,j)*par%Trep*s%urms(i,j)**3/(6.d0*par%px**2))
                        FvgCan = max((min(aht,watr)-ahtold),0d0)/s%hh(i,j)*0.5d0*s%Cdveg(i,j,m)*s%bveg(i,j,m)*s%Nveg(i,j,m)*ucan**2

                        ! decompose in u and v-direction
                        FvgCau = FvgCan*costhm(i,j)
                        FvgCav = FvgCan*sinthm(i,j)
                    endif
    
                    ! save aht to ahtold to correct possibly in next vegetation section
                    ahtold = aht
                
                    ! add Forcing current layer
                    Fvgu(i,j) = Fvgu(i,j) + Fvgtu 
                    Fvgv(i,j) = Fvgv(i,j) + Fvgtv

                    if (par%vegnonlin == 1 .and. par%wavemodel/=WAVEMODEL_NONH) then ! add nonlin wave effect
                        Fvgu(i,j) = Fvgu(i,j) + Fvgnlu
                        Fvgv(i,j) = Fvgv(i,j) + Fvgnlv
                    endif
                    if (par%vegcanflo == 1) then ! add in canopy flow (Luhar et al., 2010)
                        Fvgu(i,j) = Fvgu(i,j) + FvgCau
                        Fvgv(i,j) = Fvgv(i,j) + FvgCav
                    endif
                enddo
            endif
        enddo
    enddo

    s%Fvegu = Fvgu*par%rho ! make sure units of drag force are consistent (N/m2)
    s%Fvegv = Fvgv*par%rho ! make sure units of drag force are consistent (N/m2)

end subroutine momeqveg

subroutine swvegnonlin(s,par,unl0,etaw0)
    use params
    use spaceparams
    
    IMPLICIT NONE
    
    type(parameters)                            :: par
    type(spacepars)                             :: s
    
    integer                                     :: i,j
    integer                                     :: irf,ih0,it0,jrf,ih1,it1 !,m,ind,ih0,it0,ih1,it1,irf,jrf  ! indices of actual x,y point
    integer,  save                              :: nh,nt
    real*8                                      :: p,q,f0,f1,f2,f3 !,uabsunl,vabsvnl
    real*8,  save                               :: dh,dt
    real*8,  dimension(s%nx+1,s%ny+1)           :: kmr,Urs,phi,w1,w2
    real*8, dimension(8),save                   :: urf0
    real*8, dimension(50),save                  :: urf2,urf !,urfueurfu
    real*8, dimension(50,8),save                :: cs,sn,urf1
    real*8, dimension(:,:),save,allocatable     :: h0,t0
    real*8, dimension(s%nx+1,s%ny+1,50),intent(out) :: unl0,etaw0
   
    ! Subroutine to compute a net drag force due to wave skewness. Based on (matlab based) roller model with veggies by Ad.
    ! 
    ! Background:
    ! The drag force (Fveg) is a function of u*abs(u), which is zero for linear waves. For non-linear, skewed waves the 
    ! depth-averaged velocity integrated over the wave period is zero. However, due to the sharp peaks and flat troughs 
    ! the integral of u*abs(u) is non-zero, and can significantly reduce wave setup, or even lead to set-down (e.g. Dean & Bender,2006).
    !
    ! Here we use a method based on Rienecker & Fenton (1981), similar to the method used for onshore sediment transport due to wave asymmetry/
    ! skewness (see also morphevolution.F90 + Van Thiel de Vries Phd thesis par 6.2.3).
    !
        
    ! load Ad's RF-table (update for depth averaged velocities?)
    include 'RFveg.inc'
              
    ! Initialize/Prepare for interpolation of RF-value from RFveg-table
    if (.not. allocated(h0)) then
        allocate (h0(s%nx+1,s%ny+1))
        allocate (t0(s%nx+1,s%ny+1))

        dh = 0.03d0
        dt = 1.25d0
        nh = floor(0.54d0/dh);
        nt = floor(25.d0/dt);
        !construct velocity profile based on cosine/sine functions / Fourier components
        do irf=1,8
            do jrf=1,50                
                cs(jrf,irf) = cos((jrf*2*par%px/50)*irf)
                sn(jrf,irf) = sin((jrf*2*par%px/50)*irf)
            enddo
        enddo        
    endif

    h0 = min(nh*dh,max(dh,min(s%H,s%hh)/s%hh))
    t0 = min(nt*dt,max(dt,par%Trep*sqrt(par%g/s%hh)))
    
!    Initialize
    urf0     = 0.d0
    urf1     = 0.d0
    urf2     = 0.d0
    urf      = 0.d0
    w1       = 0.d0
    w2       = 0.d0
    phi      = 0.d0
    Urs      = 0.d0
    kmr      = 0.d0
    
    ! ! Now compute weight factors (w1,w2) for relative contribution of cosine and sine functions (for w1 = 1: only cosines -> 
    ! fully skewed Stokes wave, for w2 = 1: only sines -> fully asymmetric wave) based on Ruessink.
    kmr   = min(max(s%k, 0.01d0), 100.d0)
    Urs   = s%H/kmr/kmr/(s%hh**3)! Ursell number
       
    ! Compute phase and weight factors
    phi  = par%px/2*(1-tanh(0.815/(Urs**0.672)))! according to Ruessink et al 2012 (eq 10): p5 = 0.815 ipv 0.64; ip6 = 0.672 ipv 0.6, Dano&Ad book: 0.64 and 0.6
    w1   = 1-phi/(par%px/2)!w1 = 1.d0  if fully skewed waves
    w2   = 1.d0-w1
    ! or use relation between w1 and phi as in Phd thesis Jaap (eq 6.13)??
    
    ! Interpolate RieneckerFenton velocity from RFveg table from Ad
    ! in ftab-dimension, only read 4:11 and sum later
    do j=1,s%ny+1
       do i=1,s%nx+1 
            ! interpolate RF table values....
            ih0=floor(h0(i,j)/dh)
            it0=floor(t0(i,j)/dt)
            ih1=min(ih0+1,nh)
            it1=min(it0+1,nt)
            p=(h0(i,j)-ih0*dh)/dh
            q=(t0(i,j)-it0*dt)/dt
            f0=(1-p)*(1-q)
            f1=p*(1-q)
            f2=q*(1-p)
            f3=p*q
           
            ! Compute velocity amplitude per component
            do irf=1,8
                urf0(irf) = f0*RFveg(irf+3,ih0,it0)+f1*RFveg(irf+3,ih1,it0)+ f2*RFveg(irf+3,ih0,it1)+f3*RFveg(irf+3,ih1,it1)
            enddo

            ! fill velocity amplitude matrix urf1([50 time points, 8 components])
            do irf=1,8
                urf1(:,irf) = urf0(irf)
            enddo
            
            ! Compute velocity profile matrix per component
            urf1 = urf1*(w1(i,j)*cs+w2(i,j)*sn)
    
            ! Add velocity components
            urf2 = sum(urf1,2)
    
            ! Scale the results to get velocity profile over wave period
            unl0(i,j,:)  = urf2*sqrt(par%g*s%hh(i,j))
            etaw0(i,j,:) = unl0(i,j,:)*sqrt(max(s%hh(i,j),0.d0)/par%g)
        enddo 
    enddo
    
end subroutine swvegnonlin

function trapz(y,dx) result (value)
    implicit none
    real*8               :: integral,value,dx
    real*8, dimension(:) :: y
    integer              :: i,n

    integral = 0.d0
    n        = size(y)-1.d0
    do i=1,n
        integral = integral+dx*(y(i+1)+y(i))/2
    end do
    value = integral
    
end function trapz

subroutine bulkdragcoeff(s,par,ahh,m,i,j,Cdterm)
!    Michele Bendoni: subroutine to calculate bulk drag coefficient for short wave
!    energy dissipation based on the Keulegan-Carpenter number
!    Ozeren et al. (2013) or Mendez and Losada (2004)

    use params
    use spaceparams
    
    implicit none

    !type(veggie), dimension(:), pointer         :: veg
    
    type(parameters)     :: par
    type(spacepars)      :: s
    real*8,  intent(out) :: Cdterm
    real*8,  intent(in)  :: ahh    ! [m] plant (total) height
    integer, intent(in)  :: m,i,j
    
    ! Local variables
    real*8               :: alfav  ! [-] ratio between plant height and water depth
    real*8               :: um     ! [m/s] typical velocity acting on the plant
    real*8               :: Tp     ! [s] reference wave period
    real*8               :: KC     ! [-] Keulegan-Carpenter number
    real*8               :: Q      ! [-] modified Keulegan-Carpenter number
    integer              :: myflag ! 1 => Ozeren et al. (2013); 2 => Mendez and Losada (2004)
    !
    !
    myflag = 2
    !
    ! Representative wave period
    Tp = 2*par%px/s%sigm(i,j)
    !
    ! Coefficient alfa
    if (ahh>=s%hh(i,j)) then
       alfav = 1.d0
    else
       alfav = ahh/s%hh(i,j)
    end if
    !
    ! Representative orbital velocity
    ! (Could we also use urms here?)
    um = 0.5d0*s%H(i,j)*s%sigm(i,j)*cosh(s%k(i,j)*alfav*s%hh(i,j))/sinh(s%k(i,j)*s%hh(i,j))
    !
    ! Keulegan-Carpenter number
    KC = um*Tp/s%bveg(i,j,m)
    if (KC > 0d0) then
        KC = KC
    endif
    !
    ! Bulk drag coefficient
    if (myflag == 1) then
       ! 
       ! Approach from Ozeren et al. (2013), eq?
       !
       if (KC>=10.d0) then
          Cdterm = 0.036d0+50.d0/(KC**0.926d0)
       else
          Cdterm = 0.036d0+50.d0/(10.d0**0.926d0)
       endif
    elseif (myflag == 2) then
       !
       ! Approach from Mendez and Losada (2004), eq. 40
       ! Only applicable for Laminaria Hyperborea (kelp)???
       !
       Q = KC/(alfav**0.76d0)
       if (Q>=7) then
          Cdterm = exp(-0.0138*Q)/(Q**0.3d0)
       else
          Cdterm = exp(-0.0138*7)/(7**0.3d0)
       endif
    endif
    !
end subroutine bulkdragcoeff

subroutine porcanflow(s,par)
    ! porous in-canopy model. Computes the in-canopy flow and vegetation force.
    use params
    use spaceparams
    use readkey_module
    use xmpi_module
    use filefunctions
    use interp
    use logging_module
    
    implicit none
    
    type(parameters)                            :: par
    type(spacepars)                             :: s
    !type(veggie), dimension(:), pointer         :: veg

    ! local variables
    integer                                     :: i,j,imax,j1,switch_drag
    real*8                                      :: p,mu,lamp,Kp,beta,hcan,Cf,Cm,A,Fcanu,Fcanv,U,V,ucan_old,vcan_old !rhs,

    ! Initialization paramters 
    mu     = 10.d0**(-6)                           ! kinematic viscosity  
    Kp     = par%Kp                                ! permeability
    Cm     = par%Cm                                ! inertia coefficient
    U     = 0.d0
    V     = 0.d0
    ucan_old=0.d0
    vcan_old=0.d0
    switch_drag=1
    
    ! Superfast 1D
    if (s%ny==0) then
        j1 = 1
    else
        j1 = 2
    endif
    
    ! In canopy momentum balance
    do j=j1,max(s%ny,1)
        imax = s%nx
        do i=2,imax
            ! Only compute ucan if vegeation is pressent
            if(s%vegtype(i,j)>0.d0) then
                    ! vegetation type
                    p      = s%Nveg(i,j,1)/100.d0               ! porosity
                    lamp   = (1-p)                              ! lambda parameters (Britter and Hanna, 2003)
                    hcan   = s%ahveg(i,j,1)                     ! canopy height
                    beta   = s%Cdveg(i,j,1)                     ! Drag
                    Cf     = s%bveg(i,j,1)                     ! Friction
                
                !Emergent case. hcan> h
                if (s%hu(i,j) < hcan) then
                    hcan = s%hu(i,j)
                endif
                
                !Implicit term momentum equation
                A = (1+Cm*lamp/(1-lamp))/par%dt
                
                ! Select free stream velocity for top shear stress.
!                if (par%nonhq3d == 1 .and. par%nhlay > 0.0d0 .and. par%switch_2dv==1) then
!                    ! hcan < 0.5 alpha * h
!                    if (hcan < 0.5d0 * par%nhlay*s%hh(i,j)) then
!                        !Free stream velocity is velocity layer 1
!                        U = s%u(i,j) + (1.d0 - par%nhlay) * s%du(i,j)   
!                        V = s%v(i,j) + (1.d0 - par%nhlay) * s%dv(i,j) 
!                    ! hcan > 0.5 alpha * h + alpha * h
!                    elseif (hcan > 0.5d0 * par%nhlay * s%hh(i,j)  + par%nhlay*s%hh(i,j)) then
!                        !Free stream velocity is velocity layer 2
!                        U = s%u(i,j) - par%nhlay * s%du(i,j)
!                        V = s%v(i,j) - par%nhlay * s%dv(i,j)
!                    ! 0.5 alpha * h > hcan > 0.5 alpha * h + alpha * h
!                    else
!                        ! Velocity layer 1
!                        u11 = s%u(i,j) + (1.d0 - par%nhlay) * s%du(i,j)
!                        ! Velocity layer 2
!                        u22 = s%u(i,j) - par%nhlay * s%du(i,j)
!                        ! Interpolate between layers for smooth transition.
!                        U = (u22-u11)/(0.5d0*(1.d0 - par%nhlay) *s%hh(i,j) + 0.5d0 * par%nhlay * s%hh(i,j) ) * (hcan - 1.d0/2.d0 * par%nhlay * s%hh(i,j))
!                        
!                        ! Velocity layer 1
!                        v11 = s%v(i,j) + (1.d0 - par%nhlay) * s%dv(i,j)
!                        ! Velocity layer 2
!                        v22 = s%v(i,j) - par%nhlay * s%dv(i,j)
!                        ! Interpolate between layers for smooth transition.
!                        V = (v22-v11)/(0.5d0*(1.d0 - par%nhlay) *s%hh(i,j) + 0.5d0 * par%nhlay * s%hh(i,j) ) * (hcan - 0.5d0 * par%nhlay * s%hh(i,j))
!                    endif
!                else
!                    ! Depth averaged velocity
!                    U = s%u(i,j)
!                    V = s%v(i,j)
!                endif
                
                ! free stream velocty
                U = s%u(i,j)
                V = s%v(i,j)
                
                ! ucan previous time step
                ucan_old = s%ucan(i,j)
                vcan_old = s%vcan(i,j)
                           
                ! Compute u-incanopy velocity when cell is wet
                if (s%wetu(i,j)>0) then
                    s%ucan(i,j) = (-1 * par%g*s%dzsdx(i,j) +  0.5d0*Cf/hcan*abs(U-s%ucan(i,j)) * (U-s%ucan(i,j)) + A * s%ucan(i,j))/(A + mu * (1-lamp)/Kp + beta * abs(s%ucan(i,j)))
                    ! prevent high in-canopy for flooding
                    !if ((s%ucan(i,j)-ucan_old)/par%dt > 0.2) then
                    !    s%ucan(i,j) = ucan_old
                    !endif
                ! Zero velocity if dry    
                else
                    s%ucan(i,j) = 0.d0
                endif
                
                ! Compute v-incanopy velocity when cell is wet
                if (s%wetv(i,j)>0 .and. s%ny>1) then 
                    s%vcan(i,j) = (-1 * par%g*s%dzsdx(i,j) +  0.5d0*Cf/hcan*abs(V-s%vcan(i,j)) * (V-s%vcan(i,j)) + A * s%vcan(i,j))/(A + mu * (1-lamp)/Kp + beta * abs(s%vcan(i,j)))
                    ! prevent high in-canopy for flooding
                    !if (abs(s%vcan(i,j)) > abs(10 * vcan_old)) then
                    !    s%vcan(i,j) = vcan_old
                    !endif
                ! Zero velocity if dry 
                else
                    s%vcan(i,j) = 0.d0
                endif
                
                ! old shear stress formulation. u|u| instead of (u-uc)|u-uc|
                !s%ucan(i,j) = (-1 * par%g*s%dzsdx(i,j) +  abs(U)*U/(2.d0*hcan/Cf) + A * s%ucan(i,j))/(A + mu * (1-lamp)/Kp + beta * abs(s%ucan(i,j)))
            
            !Zero velocity if no vegetation
            else
                s%ucan(i,j) = 0.0d0
                s%vcan(i,j) = 0.0d0
            endif
            
            !Upper limit canopy flow???
            ! not used, because there can be a phase difference between uc and u.
            !if ( abs(s%ucan(i,j))>abs(U)) then
            !    s%ucan(i,j) = U
            !endif             
            
            ! Compute canopy drag force
            if(s%nsecveg(i,j)>0.d0 .and. switch_drag==1) then
                ! Compute vegetation force
                if (s%wetu(i,j)>0) then                    
                    Fcanu = abs(s%ucan(i,j))*ucan_old*beta + mu*(1-lamp)/Kp*ucan_old + Cm*lamp/(1-lamp) * (s%ucan(i,j)-ucan_old)/par%dt   
                else
                    Fcanu = 0.d0
                endif
                
                
                if (s%wetv(i,j)>0 .and. s%ny>1) then 
                    Fcanv = abs(s%vcan(i,j))*vcan_old*beta + mu*(1-lamp)/Kp*vcan_old + Cm*lamp/(1-lamp) * (s%vcan(i,j)-vcan_old)/par%dt
                else
                    Fcanv = 0.d0
                endif
                    
                !dfu for XBeach-nh+.
                !if (hcan > par%nhlay*s%hh(i,j) .and. par%switch_2dv==1) then
                !   s%dFvegu(i,j) = Fcanu * par%nhlay*s%hh(i,j)* par%rho - Fcanu * (hcan - par%nhlay*s%hh(i,j))* par%rho
                !else if (hcan < par%nhlay*s%hh(i,j) .and. par%switch_2dv==1) then
                !    s%dFvegu(i,j) = Fcanu * hcan * par%rho
                !else
                !    s%dFvegu(i,j) = 0
                !endif  
                
                ! Force times height and rho (divide by rho in momentum eq).
                Fcanu = Fcanu * par%rho * hcan 
                Fcanv = Fcanv * par%rho * hcan   
            else
                Fcanu = 0.
                Fcanv = 0.
            endif
            s%Fvegu(i,j) = Fcanu
            s%Fvegv(i,j) = Fcanv 
        end do
    end do

end subroutine porcanflow

end module vegetation_module
