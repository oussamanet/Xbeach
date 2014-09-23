module wave_directions_module
contains
  subroutine wave_directions(s,par)
    use params
    use spaceparams
    use roelvink_module
    use wave_functions_module
    use xmpi_module
    use logging_module

    ! wwvv in my testcase, this routine was not called, so it is not
    ! tested. Nevertheless, I put in code for the parallel version.

    IMPLICIT NONE

    type(spacepars), target     :: s
    type(parameters)            :: par

    integer                     :: i,imax,i1
    integer                     :: j
    integer                     :: itheta,iter
    real*8,dimension(:),allocatable,save        :: dist,factor,e01
    integer, dimension(:,:,:),allocatable,save  :: wete
    real*8 , dimension(:,:)  ,allocatable,save  :: dhdx,dhdy,dudx,dudy,dvdx,dvdy
    real*8 , dimension(:,:)  ,allocatable,save  :: km,uorb
    real*8 , dimension(:,:)  ,allocatable,save  :: kmx,kmy,sinh2kh ! ,wm
    real*8 , dimension(:,:,:),allocatable,save  :: xadvec,yadvec,thetaadvec,dd
    real*8 , dimension(:,:,:),allocatable,save  :: cgxu,cgyv
    real*8 , dimension(:),allocatable,save      :: Hprev
    real*8                                      :: Herr,dtw,E0
    real*8 , dimension(:)  ,allocatable,save    :: dkmxdx,dkmxdy,dkmydx,dkmydy,cgxm,cgym,arg,fac,xwadvec,ywadvec
    real*8 , dimension(:,:),allocatable,save    :: wcifacu,wcifacv
    logical                                     :: stopiterate

    include 's.ind'
    include 's.inp'

    if (.not. allocated(wete)) then
       allocate(e01(1:ntheta_s))
       allocate(dist(1:ntheta_s))
       allocate(factor(1:ntheta_s))
       allocate(wete      (nx+1,ny+1,ntheta_s))
       allocate(xadvec    (nx+1,ny+1,ntheta_s))
       allocate(yadvec    (nx+1,ny+1,ntheta_s))
       allocate(thetaadvec(nx+1,ny+1,ntheta_s))
       allocate(dd        (nx+1,ny+1,ntheta_s))
 
       allocate(cgxu        (nx+1,ny+1,ntheta_s))
       allocate(cgyv        (nx+1,ny+1,ntheta_s))

       allocate(dhdx(nx+1,ny+1))
       allocate(dhdy(nx+1,ny+1))
       allocate(dudx(nx+1,ny+1))
       allocate(dudy(nx+1,ny+1))
       allocate(dvdx(nx+1,ny+1))
       allocate(dvdy(nx+1,ny+1))
       allocate(km  (nx+1,ny+1))
       allocate(uorb(nx+1,ny+1))
       allocate(kmx (3,ny+1))
       allocate(kmy (3,ny+1))
       allocate(xwadvec(ny+1))
       allocate(ywadvec(ny+1))
       allocate(sinh2kh(nx+1,ny+1))
       allocate(Hprev(ny+1))

       allocate(dkmxdx  (ny+1))
       allocate(dkmxdy  (ny+1))
       allocate(dkmydx  (ny+1))
       allocate(dkmydy  (ny+1))
       allocate(cgxm    (ny+1))
       allocate(cgym    (ny+1))
       allocate(arg     (ny+1))
       allocate(fac     (ny+1))
       allocate(wcifacu     (nx+1,ny+1))
       allocate(wcifacv     (nx+1,ny+1))

    endif

    wete        = 0
    xadvec      = 0.0d0
    yadvec      = 0.0d0
    thetaadvec  = 0.0d0
    dd          = 0.0d0
    dhdx        = 0.0d0
    dhdy        = 0.0d0
    dudx        = 0.0d0
    dudy        = 0.0d0
    dvdx        = 0.0d0
    dvdy        = 0.0d0
    km          = 0.0d0
    kmx         = 0.0d0
    kmy         = 0.0d0
    !wm          = 0.0d0
    xwadvec     = 0.0d0
    ywadvec     = 0.0d0
    sinh2kh     = 0.0d0

    dkmxdx      = 0.0d0
    dkmxdy      = 0.0d0
    dkmydx      = 0.0d0
    dkmydy      = 0.0d0
    cgxm        = 0.0d0
    cgym        = 0.0d0

    arg         = 0.0d0
    fac         = 0.0d0

    ! cjaap: replaced par%hmin by par%eps
    hh = max(hh,par%eps)


    ! Slopes of water depth
    call slope2D(max(hh,par%delta*H),nx,ny,dsu,dnv,dhdx,dhdy)
    ! Dano limit slopes used in refraction to avoid unrealistic refraction speeds
    dhdx=sign(1.d0,dhdx)*min(abs(dhdx),0.1d0)
    dhdy=sign(1.d0,dhdy)*min(abs(dhdy),0.1d0)
    call slope2D(u*par%wci,nx,ny,dsu,dnv,dudx,dudy)
    call slope2D(v*par%wci,nx,ny,dsu,dnv,dvdx,dvdy)

    ! wwvv these slope routines are in wave_timestep, and are
    !   MPI-aware
    !
    ! Calculate once sinh(2kh)
    where(2*hh*k<=3000.d0)
       sinh2kh=sinh(min(2*k*max(hh,par%delta*H),10.0d0))
    elsewhere
       sinh2kh = 3000.d0
    endwhere

 !   Dano: This is already done in wave_bc   
 !   call dispersion(par,s)   

 !   if (par%wci==0) then
 !      sigm=2.d0*par%px/par%Trep
 !      sigm = max(sigm,0.010d0)
 !   endif

    ! Calculate once velocities used with and without wave current interaction
    wcifacu=u*par%wci*min(hh/par%hwci,1.d0)
    wcifacv=v*par%wci*min(hh/par%hwci,1.d0)

    DO itheta=1,ntheta_s
       cgx_s(:,:,itheta)= cg*costh_s(:,:,itheta)+wcifacu
       cgy_s(:,:,itheta)= cg*sinth_s(:,:,itheta)+wcifacv
       ctheta_s(:,:,itheta)=  &
            sigm/sinh2kh*(dhdx*sinth_s(:,:,itheta)-dhdy*costh_s(:,:,itheta)) + &
            par%wci*(&
            costh_s(:,:,itheta)*(sinth_s(:,:,itheta)*dudx - costh_s(:,:,itheta)*dudy) + &
            sinth_s(:,:,itheta)*(sinth_s(:,:,itheta)*dvdx - costh_s(:,:,itheta)*dvdy))
    END DO
    ! Dano Limit unrealistic refraction speed to 1/2 pi per wave period
    ctheta_s=sign(1.d0,ctheta_s)*min(abs(ctheta_s),.5*par%px/par%Trep)
    km = k

    ! Dano Temporary solution to obtain Hrms, Trep and m from params file
    
    dist=(cos(theta_s-theta0))**par%m
    do i=1,ntheta_s
       if(cos(theta_s(i)-theta0)<0.d0) then
          dist(i)=0.0d0
       end if
    end do
    if (sum(dist)>0.d0) then 
       factor = (dist/sum(dist))/dtheta
    else
       factor=0.d0
    endif
    E0=0.125d0*par%rho*par%g*par%Hrms**2
    e01    = factor*E0
    e01    = max(e01,0.0d0)
    do j=1,ny+1
       ee_s(1,j,:)=e01
    end do
    thetamean=(sum(ee_s*thet_s,3)/ntheta_s)/(max(sum(ee_s,3),0.00001d0)/ntheta_s)

    !dtw=.9*minval(xz(2:nx+1)-xz(1:nx))/maxval(cgx_s)

       E(1,:)=sum(ee_s(1,:,:),2)*dtheta
       H(1,:)=sqrt(E(1,:)/par%rhog8)

       imax=nx
!Dano  This is ok, since we will set mpiboundary to y in stationary mode

       do i=2,imax
          dtw=.5*minval(dsu(i:i+1,jmin_ee:jmax_ee))/maxval(cgx_s(i-1:i+1,jmin_ee:jmax_ee,:))
          dtw=min(dtw,.5*minval(dnv(i,jmin_ee:jmax_ee))/maxval(abs(cgy_s(i,jmin_ee:jmax_ee,:))))
          dtw=min(dtw,.5*dtheta/maxval(abs(ctheta_s(i,jmin_ee:jmax_ee,:))))
!Dano: need to make sure all processes use the same dtw, min of all processes
#ifdef USEMPI
          call xmpi_allreduce(dtw,MPI_MIN)
#endif
          Herr=1.
          iter=0
          arg = min(100.0d0,km(i,:)*(hh(i,:)+par%delta*H(i,:)))
          arg = max(arg,0.0001)
          fac = ( 1.d0 + ((km(i,:)*H(i,:)/2.d0)**2))  ! use deep water correction instead of expression above (waves are short near blocking point anyway)
          stopiterate=.false.
          do while (stopiterate .eqv. .false.)
             iter=iter+1
             Hprev=H(i,:)
             ! WCI
             if (par%wci==1) then
                ! Dano NEED TO CHECK THIS FOR CURVI
                kmx = km(i-1:i+1,:)*cos(thetamean(i-1:i+1,:)-alfaz(i-1:i+1,:))
                kmy = km(i-1:i+1,:)*sin(thetamean(i-1:i+1,:)-alfaz(i-1:i+1,:))
                wm(i-1:i+1,:) = sigm(i-1:i+1,:)+kmx*wcifacu(i-1:i+1,:)&
                     +kmy*wcifacv(i-1:i+1,:)

                where(km(i,:)>0.01d0)
                   c(i,:)  = sigm(i,:)/km(i,:)
                   cg(i,:) = c(i,:)*(0.5d0+arg/sinh(2*arg))*sqrt(fac)  
                   n(i,:)  = 0.5d0+km(i,:)*hh(i,:)/sinh(2*max(km(i,:),0.00001d0)*hh(i,:))
                elsewhere
                   c(i,:)  = 0.01d0
                   cg(i,:) = 0.01d0
                   n(i,:)  = 1.d0
                endwhere

                cgym = cg(i,:)*dsin(thetamean(i,:)-alfaz(i,:)) + wcifacv(i,:)
                cgxm = cg(i,:)*dcos(thetamean(i,:)-alfaz(i,:)) + wcifacu(i,:)

                dkmxdx       = (kmx(3,:)-kmx(1,:))/(dsu(i,:)+dsu(i+1,:))
                dkmxdy(2:ny) = (kmx(2,3:ny+1)-kmx(2,1:ny-1))/(dnv(i,2:ny)+dnv(i,3:ny+1))
                dkmxdy(1)    = dkmxdy(2)
                dkmxdy(ny+1) = dkmxdy(ny)
                dkmydx       = (kmy(3,:)-kmy(1,:))/(dsu(i,:)+dsu(i+1,:))
                dkmydy(2:ny) = (kmy(2,3:ny+1)-kmy(2,1:ny-1))/(dnv(i,2:ny)+dnv(i,3:ny+1))
                dkmydy(1)    = dkmydy(2)
                dkmydy(ny+1) = dkmydy(ny)

                xwadvec  = (wm(i,:)-wm(i-1,:))/dsu(i-1,:)
                kmx(2,:) = kmx(2,:) -dtw*xwadvec -dtw*cgym*(dkmydx-dkmxdy)

                ywadvec(2:ny) = (wm(i,3:ny+1)-wm(i,1:ny-1))/(dnv(i,2:ny)+dnv(i,3:ny+1))
                ywadvec(1)=ywadvec(2)
                ywadvec(ny+1)=ywadvec(ny)
                kmy(2,:) = kmy(2,:) -dtw*ywadvec + dtw*cgxm*(dkmydx-dkmxdy)

                ! Dano
#ifdef USEMPI
                call xmpi_shift(kmx(1:2,:),SHIFT_Y_R,1,2)
                call xmpi_shift(kmx(1:2,:),SHIFT_Y_L,3,4)
                call xmpi_shift(kmy(1:2,:),SHIFT_Y_R,1,2)
                call xmpi_shift(kmy(1:2,:),SHIFT_Y_L,3,4)
#endif
                km(i,:) = sqrt(kmx(2,:)**2+kmy(2,:)**2)
                km(i,:) = min(km(i,:),25.d0) ! limit to gravity waves

                !  non-linear dispersion
                arg = min(100.0d0,km(i,:)*(hh(i,:)+par%delta*H(i,:)))
                arg = max(arg,0.0001)
                fac = ( 1.d0 + ((km(i,:)*H(i,:)/2.d0)**2)) 
                sigm(i,:) = sqrt( par%g*km(i,:)*tanh(arg)*fac)
                sigm(i,:) = max(sigm(i,:),0.010d0)
             endif

             !
             ! transform to wave action
             !
             i1=max(i-2,1)
             do itheta=1,ntheta_s
                ee_s(i1:i+1,:,itheta) = ee_s(i1:i+1,:,itheta)/sigm(i1:i+1,:)
             enddo
             !
             ! Upwind Euler timestep propagation
             !
             if  (i>2.and. par%scheme==SCHEME_UPWIND_2) then
                call advecxho(ee_s(i-2:i+1,:,:),cgx_s(i-2:i+1,:,:),xadvec(i-2:i+1,:,:),    &
                     3,ny,ntheta_s,dnu(i-2:i+1,:),dsu(i-2:i+1,:),dsdnzi(i-2:i+1,:),SCHEME_UPWIND_2)
             else
                call advecxho(ee_s(i-1:i+1,:,:),cgx_s(i-1:i+1,:,:),xadvec(i-1:i+1,:,:),    &
                     2,ny,ntheta_s,dnu(i-1:i+1,:),dsu(i-1:i+1,:),dsdnzi(i-1:i+1,:),SCHEME_UPWIND_1)
             endif
             call advecyho(ee_s(i,:,:),cgy_s(i,:,:),yadvec(i,:,:),                                  &
                  0,ny,ntheta_s,dsv(i,:),dnv(i,:),dsdnzi(i,:),SCHEME_UPWIND_1)
             call advecthetaho(ee_s(i,:,:),ctheta_s(i,:,:),thetaadvec(i,:,:),0,ny,ntheta_s,dtheta,par%scheme)

             ee_s(i,:,:)=ee_s(i,:,:)-dtw*(xadvec(i,:,:) + yadvec(i,:,:) &
                  + thetaadvec(i,:,:))
#ifdef USEMPI
             call xmpi_shift(ee_s(i-1:i,:,:),SHIFT_Y_R,1,2)
             call xmpi_shift(ee_s(i-1:i,:,:),SHIFT_Y_L,3,4)
#endif
             !
             ! transform back to wave energy
             !
             do itheta=1,ntheta_s
                ee_s(i1:i+1,:,itheta) = ee_s(i1:i+1,:,itheta)*sigm(i1:i+1,:)
             enddo
             ee_s(i,:,:)=max(ee_s(i,:,:),0.0d0)


             !
             ! Energy integrated over wave directions,Hrms
             !
             E(i,:)=sum(ee_s(i,:,:),2)*dtheta
             H(i,:)=sqrt(E(i,:)/par%rhog8)
             do itheta=1,ntheta_s
                ee_s(i,:,itheta)=ee_s(i,:,itheta)/max(1.0d0,(H(i,:)/(par%gammax*hh(i,:)))**2)
             enddo
             H(i,:)=min(H(i,:),par%gammax*hh(i,:))
             E(i,:)=par%rhog8*H(i,:)**2

             if (par%snells==0) then !Dano not for SNellius
                thetamean(i,:) = (sum(ee_s(i,:,:)*thet_s(i,:,:),2)/ntheta_s)/(max(sum(ee_s(i,:,:),2),0.000010d0)/ntheta_s)
             endif
             !
             ! Total dissipation

             select case(par%break)
               case(BREAK_ROELVINK1,BREAK_ROELVINK2)
                 call roelvink       (par,s,km(i,:),i)
               case(BREAK_BALDOCK)
                 call baldock        (par,s,km(i,:),i)
               case(BREAK_JANSSEN)
                 call janssen_battjes(par,s,km(i,:),i)
             end select


             ! Dissipation by bed friction
             uorb(i,:)=par%px*H(i,:)/par%Trep/sinh(min(max(k(i,:),0.01d0)*max(hh(i,:),par%delta*H(i,:)),10.0d0))
             Df(i,:)=0.6666666d0/par%px*par%rho*par%fw*uorb(i,:)**3
             where (hh>par%fwcutoff)
                Df = 0.d0
             end where
             !
             ! Distribution of dissipation over directions and frequencies
             !
             do itheta=1,ntheta_s
                dd(i,:,itheta)=ee_s(i,:,itheta)*(D(i,:)+Df(i,:))/max(E(i,:),0.00001d0)
             end do
             do j=1,ny+1
                ! cjaap: replaced par%hmin by par%eps
                if(hh(i,j)+par%delta*H(i,j)>par%eps) then
                   wete(i,j,1:ntheta_s)=1
                else
                   wete(i,j,1:ntheta_s)=0
                end if
             end do
             !
             ! Euler step dissipation
             !
             do j=jmin_ee,jmax_ee
                do itheta=1,ntheta_s        
                   if (dtw*dd(i,j,itheta)>ee_s(i,j,itheta)) then
                      dtw=min(dtw,.5*ee_s(i,j,itheta)/dd(i,j,itheta))                
                   endif
                enddo
             enddo
!Dano: need to make sure all processes use the same dtw, min of all processes
#ifdef USEMPI
             call xmpi_allreduce(dtw,MPI_MIN)
#endif
             do j=1,ny+1
                do itheta=1,ntheta_s                        
                   if(wete(i,j,itheta)==1) then
                      ee_s(i,j,itheta)=ee_s(i,j,itheta)-dtw*dd(i,j,itheta)
                      ee_s(i,j,itheta)=max(ee_s(i,j,itheta),0.0d0)
                   else if(wete(i,j,itheta)==0) then
                      ee_s(i,j,itheta)=0.0d0
                   end if
                end do
             end do
             ! Lateral boundary condition
             if (xmpi_isleft .and. ny>0) then
                do itheta=1,ntheta_s
                   if (sinth_s(i,1,itheta)>=0.) then
                      ee_s(i,1,itheta)=ee_s(i,2,itheta)
                   endif
                enddo
                km(:,1)=km(:,2)
                sigm(:,1)=sigm(:,2)
             endif
             if (xmpi_isright .and. ny>0) then
                do itheta=1,ntheta_s 
                   if (sinth_s(i,ny+1,itheta)<=0.) then
                      ee_s(i,ny+1,itheta)=ee_s(i,ny,itheta)
                   endif
                end do
                km(:,ny+1)=km(:,ny)
                sigm(:,ny+1)=sigm(:,ny)
             endif
             !
             ! Compute mean wave direction
             !
             if (par%snells==0) then
                thetamean(i,:)=(sum(ee_s(i,:,:)*thet_s(i,:,:),2)/size(ee_s(i,:,:),2)) &
                     /(max(sum(ee_s(i,:,:),2),0.000010d0) /size(ee_s(i,:,:),2))
             endif
             !
             ! Energy integrated over wave directions,Hrms
             !
             E(i,:)=sum(ee_s(i,:,:),2)*dtheta
             H(i,:)=sqrt(E(i,:)/par%rhog8)
             Herr=maxval(abs(Hprev(jmin_ee:jmax_ee)-H(i,jmin_ee:jmax_ee)))
#ifdef USEMPI
             call xmpi_allreduce(Herr,MPI_MAX)   
#endif
             ! Stopping criteria
             if (iter<par%maxiter) then
                if (Herr<par%maxerror) then
                   stopiterate=.true.
                   if(xmaster) call writelog('ls','(a,i4,a,i4)','Wave propagation row ',i,', iteration ',iter)
                endif
             else
                stopiterate=.true.
                if(xmaster) call writelog('ls','(a,i4,a,i4,a,f5.4)','Wave propagation row ',i,', iteration ',iter,', error: ',Herr)
             endif
          enddo ! End while loop
       enddo ! End do i=2:nx loop  

    ee_s(nx+1,:,:) = ee_s(nx,:,:)
    E(nx+1,:)    = E(nx,:)
    H(nx+1,:)    = H(nx,:)
    km(nx+1,:)   = km(nx,:)
    sigm(nx+1,:) = sigm(nx,:)
    cg(nx+1,:)   = cg(nx,:)
    c(nx+1,:)    = c(nx,:)
    thet_s(nx+1,:,:) = thet_s(nx,:,:)
    k=km
  end subroutine wave_directions
end module wave_directions_module