!!       __  _______________
!!      /  |/  / ____/ ____/
!!     / /|_/ / /_  / /     
!!    / /  / / __/ / /___   
!!   /_/  /_/_/    \____/   
!!                       
!!  This file is part of MFC.
!!
!!  MFC is the legal property of its developers, whose names 
!!  are listed in the copyright file included with this source 
!!  distribution.
!!
!!  MFC is free software: you can redistribute it and/or modify
!!  it under the terms of the GNU General Public License as published 
!!  by the Free Software Foundation, either version 3 of the license 
!!  or any later version.
!!
!!  MFC is distributed in the hope that it will be useful,
!!  but WITHOUT ANY WARRANTY; without even the implied warranty of
!!  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
!!  GNU General Public License for more details.
!!  
!!  You should have received a copy of the GNU General Public License
!!  along with MFC (LICENSE).  
!!  If not, see <http://www.gnu.org/licenses/>.

!>
!! @file m_qbmm.f90
!! @brief Contains module m_qbmm
!! @author S. Bryngelson
!! @version 1.0
!! @date MAY 28, 2020

!> @brief This module is used to compute moment inversion via qbmm
MODULE m_qbmm

    ! Dependencies =============================================================

    USE m_derived_types        !< Definitions of the derived types

    USE m_global_parameters    !< Definitions of the global parameters
    
    USE m_mpi_proxy            !< Message passing interface (MPI) module proxy
    
    USE m_variables_conversion !< State variables type conversion procedures

    ! ==========================================================================

    IMPLICIT NONE


    REAL(KIND(0d0)), PARAMETER :: verysmall = 1.D-12
    REAL(KIND(0d0)), ALLOCATABLE, DIMENSION(:,:,:,:,:)  :: momrhs


    CONTAINS


        SUBROUTINE s_initialize_qbmm_module()

            INTEGER :: i1,i2,q

            ALLOCATE( momrhs(0:2,0:2,nb,nterms,3) )
            momrhs = 0d0

            ! Assigns the required RHS moments for moment transport equations
            ! The rhs%(:,3) is only to be used for R0 quadrature, not for computing X/Y indices
            DO q = 1,nb
                DO i1 = 0,2; DO i2 = 0,2
                    IF ( (i1+i2)<=2 ) THEN
                        momrhs(i1,i2,q,1,1) = -1.d0 + i1
                        momrhs(i1,i2,q,1,2) = -1.d0 + i2
                        momrhs(i1,i2,q,1,3) = 0d0

                        momrhs(i1,i2,q,2,1) = -1.d0 + i1
                        momrhs(i1,i2,q,2,2) =  1.d0 + i2
                        momrhs(i1,i2,q,2,3) = 0d0

                        momrhs(i1,i2,q,3,1) = -1.d0 + i1 - 3.d0*gam
                        momrhs(i1,i2,q,3,2) = -1.d0 + i2
                        momrhs(i1,i2,q,3,3) = 3.d0*gam

                        momrhs(i1,i2,q,4,1) = -1.d0 + i1
                        momrhs(i1,i2,q,4,2) =  1.d0 + i2
                        momrhs(i1,i2,q,4,3) = 0d0

                        IF (Re_inv .NE. dflt_real) THEN
                            ! add viscosity
                            momrhs(i1,i2,q,5,1) = -2.d0 + i1
                            momrhs(i1,i2,q,5,2) = i2
                            momrhs(i1,i2,q,5,3) = 0d0
                        END IF

                        IF (Web .NE. dflt_real) THEN
                            ! add surface tension
                            momrhs(i1,i2,q,6,1) = -2.d0 + i1
                            momrhs(i1,i2,q,6,2) = -1.d0 + i2
                            momrhs(i1,i2,q,6,3) = 0d0
                        END IF
                    END IF
                END DO; END DO 
            END DO

        END SUBROUTINE s_initialize_qbmm_module


        SUBROUTINE s_mom_inv( q_prim_vf, momsp, moms3d, is1, is2, is3 ) 
            
            TYPE(scalar_field), DIMENSION(sys_size), INTENT(IN) :: q_prim_vf
            TYPE(scalar_field), DIMENSION(nmomsp), INTENT(INOUT) :: momsp
            TYPE(scalar_field), DIMENSION(0:2,0:2,nb), INTENT(INOUT) :: moms3d
            TYPE(bounds_info), INTENT(IN) :: is1,is2,is3

            REAL(KIND(0d0)), DIMENSION(nmom) :: moms
            REAL(KIND(0d0)), DIMENSION(nb) :: Rvec
            REAL(KIND(0d0)), DIMENSION(nb,nnode) :: wght, abscX, abscY
            REAL(KIND(0d0)), DIMENSION(nterms,0:2,0:2) :: mom3d_terms
            REAL(KIND(0d0)) :: pres, rho, nbub

            INTEGER :: j,k,l,q,r,s !< Loop variables
            INTEGER :: id1,id2,id3
            INTEGER :: i1,i2

            DO id3 = is3%beg, is3%end; DO id2 = is2%beg, is2%end; DO id1 = is1%beg, is1%end

                IF (q_prim_vf(alf_idx)%sf(id1,id2,id3) > small_alf) THEN

                    pres = q_prim_vf(E_idx)%sf(id1,id2,id3)
                    rho  = q_prim_vf(cont_idx%beg)%sf(id1,id2,id3)
                    ! SHB: Manually adjusted pressure here for no-coupling case
                    ! pres = 1d0/0.3d0

                    DO q = 1,nb
                        Rvec(q) = q_prim_vf(bub_idx%rs(q))%sf(id1,id2,id3)
                    END DO
                    CALL s_comp_n_from_prim( q_prim_vf(alf_idx)%sf(id1,id2,id3), Rvec, nbub )

                    DO q = 1,nb
                        DO r = 1,nmom
                            moms(r) = q_prim_vf(bub_idx%moms(q,r))%sf(id1,id2,id3)
                        END DO

                        IF(id1==0) THEN
                            PRINT*, 'pres: ', pres
                            PRINT*, 'nb : ', nbub
                            PRINT*, 'alf: ', q_prim_vf(alf_idx)%sf(id1,id2,id3)
                            DO s = 1,nmom
                                PRINT*, 'mom: ', moms(s)
                            END DO
                        END IF

                        CALL s_chyqmom(moms,wght(q,:),abscX(q,:),abscY(q,:))

                        ! IF (id1==0) THEN
                        !     PRINT*, 'wght', wght(q,:)
                        !     PRINT*, 'abscX', abscX(q,:)
                        !     PRINT*, 'abscY', abscY(q,:)
                        !     call s_mpi_abort()
                        ! END IF

                        DO j = 1,nterms
                            DO i1 = 0,2; DO i2 = 0,2
                                IF ( (i1+i2)<=2 ) THEN
                                    mom3d_terms(j,i1,i2) = f_coeff(j,i1,i2,pres,rho)    & 
                                    * (R0(q)**momrhs(i1,i2,q,j,3))                  &
                                    * f_quad2D(abscX(q,:),abscY(q,:),wght(q,:),momrhs(i1,i2,q,j,:))
                                END IF
                            END DO; END DO
                        END DO

                        DO i1 = 0,2; DO i2 = 0,2
                            IF ( (i1+i2)<=2 ) THEN
                                moms3d(i1,i2,q)%sf(id1,id2,id3) = nbub*SUM( mom3d_terms(:,i1,i2) )
                                IF (moms3d(i1,i2,q)%sf(id1,id2,id3) .NE. moms3d(i1,i2,q)%sf(id1,id2,id3)) THEN
                                    PRINT*, 'nan in mom3d', i1,i2,id1
                                    PRINT*, 'nbu: ', nbub
                                    PRINT*, 'alf: ', q_prim_vf(alf_idx)%sf(id1,id2,id3)
                                    PRINT*, 'moms: ', moms(:)
                                    CALL s_mpi_abort()
                                END IF
                            END IF
                        END DO; END DO
                    END DO

                    momsp(1)%sf(id1,id2,id3) = f_quad(abscX,abscY,wght,3d0,0d0,0d0)
                    momsp(2)%sf(id1,id2,id3) = 4.d0*pi*nbub*f_quad(abscX,abscY,wght,2d0,1d0,0d0)
                    momsp(3)%sf(id1,id2,id3) = f_quad(abscX,abscY,wght,3d0,2d0,0d0)
                    momsp(4)%sf(id1,id2,id3) = f_quad(abscX,abscY,wght,3d0*(1d0-gam),0d0,3d0*gam)

                    DO i1 = 1,nterms
                        IF (momsp(i1)%sf(id1,id2,id3) .NE. momsp(i1)%sf(id1,id2,id3)) THEN
                            PRINT*, 'nan in momsp', i1,id1
                            PRINT*, 'moms: ', moms(:)
                            call s_mpi_abort()
                        END IF
                    END DO

                ELSE

                    DO q = 1,nb
                        IF(id1==0) THEN
                            PRINT*, 'alf: ', q_prim_vf(alf_idx)%sf(id1,id2,id3)
                            DO s = 1,nmom
                                PRINT*, 'mom: ', q_prim_vf(bub_idx%moms(q,s))%sf(id1,id2,id3)
                            END DO
                        END IF

                        DO i1 = 0,2; DO i2 = 0,2
                            moms3d(i1,i2,q)%sf(id1,id2,id3) = 0d0
                        END DO; END DO
                    END DO

                    momsp(1)%sf(id1,id2,id3) = 0d0 
                    momsp(2)%sf(id1,id2,id3) = 0d0 
                    momsp(3)%sf(id1,id2,id3) = 0d0 
                    momsp(4)%sf(id1,id2,id3) = 0d0 

                END IF

            END DO; END DO; END DO

        END SUBROUTINE s_mom_inv


        SUBROUTINE s_chyqmom(momin,wght,abscX,abscY)
            
            REAL(KIND(0d0)), DIMENSION(nnode), INTENT(INOUT) :: wght,abscX,abscY
            REAL(KIND(0d0)), DIMENSION(nmom), INTENT(IN) :: momin
    
            REAL(KIND(0d0)), DIMENSION(0:nmom,0:nmom) :: moms
            REAL(KIND(0d0)), DIMENSION(3) :: M1, M3
            REAL(KIND(0d0)), DIMENSION(2) :: myrho, myrho3, up, up3, Vf
            REAL(KIND(0d0)) :: bu, bv, d20, d11, d02, c20, c11, c02
            REAL(KIND(0d0)) :: mu2avg, mu2, vp21, vp22, rho21, rho22

            moms(0,0) = momin(1)
            moms(1,0) = momin(2)
            moms(0,1) = momin(3)
            moms(2,0) = momin(4)
            moms(1,1) = momin(5)
            moms(0,2) = momin(6)

            bu  = moms(1,0)/moms(0,0)
            bv  = moms(0,1)/moms(0,0)
            d20 = moms(2,0)/moms(0,0)
            d11 = moms(1,1)/moms(0,0)
            d02 = moms(0,2)/moms(0,0)
            c20 = d20 - bu**2d0; 
            c11 = d11 - bu*bv;
            c02 = d02 - bv**2d0; 

            M1 = (/ 1d0, 0d0, c20 /)
            CALL s_hyqmom(myrho,up,M1)
            Vf = c11*up/c20

            mu2avg = c02 - SUM(myrho(:)*(Vf(:)**2d0))
            mu2avg = MAXVAL( (/ mu2avg, 0d0 /) )
            mu2 = mu2avg 
            M3 = (/ 1d0, 0d0, mu2 /)
            CALL s_hyqmom(myrho3,up3,M3)

            vp21 = up3(1)
            vp22 = up3(2)
            rho21 = myrho3(1)
            rho22 = myrho3(2)

            wght(1) = myrho(1)*rho21 
            wght(2) = myrho(1)*rho22 
            wght(3) = myrho(2)*rho21 
            wght(4) = myrho(2)*rho22 
            wght = moms(0,0)*wght

            abscX(1) = up(1) 
            abscX(2) = up(1) 
            abscX(3) = up(2) 
            abscX(4) = up(2) 
            abscX = bu + abscX

            abscY(1) = Vf(1) + vp21 
            abscY(2) = Vf(1) + vp22 
            abscY(3) = Vf(2) + vp21 
            abscY(4) = Vf(2) + vp22 
            abscY = bv + abscY

        END SUBROUTINE s_chyqmom


        SUBROUTINE s_hyqmom(frho,fup,fmom)
            
            REAL(KIND(0d0)), DIMENSION(2), INTENT(INOUT) :: frho, fup
            REAL(KIND(0d0)), DIMENSION(3), INTENT(IN) :: fmom
            REAL(KIND(0d0)) :: bu, d2, c2

            bu = fmom(2)/fmom(1)
            d2 = fmom(3)/fmom(1)
            c2 = d2 - bu**2d0 
            frho(1) = fmom(1)/2d0; 
            frho(2) = fmom(1)/2d0; 
            c2 = MAXVAL( (/ c2,verysmall /) )
            fup(1) = bu - DSQRT(c2)
            fup(2) = bu + DSQRT(c2) 

        END SUBROUTINE s_hyqmom


        FUNCTION f_coeff( term,i1,i2,pres,rho )
            INTEGER, INTENT(IN) :: term,i1,i2
            REAL(KIND(0.D0)), INTENT(IN) :: pres, rho
            REAL(KIND(0.D0)) :: f_coeff

            IF (term == 1) THEN
                f_coeff = -1d0*i2*pres/rho
            ELSEIF (term == 2) THEN
                f_coeff = -3d0*i2/2d0
            ELSEIF (term == 3) THEN
                f_coeff = i2/rho
            ELSEIF (term == 4) THEN
                f_coeff = i1
            ELSEIF (term == 5) THEN
                IF (Re_inv .NE. dflt_real) THEN
                    f_coeff = 4d0*i2*Re_inv/rho
                ELSE
                    f_coeff = 0d0
                END IF
            ELSEIF (term == 6) THEN
                IF (Web .NE. dflt_real) THEN
                    f_coeff = 2*i2/Web/rho
                ELSE
                    f_coeff = 0d0
                END IF
            END IF

        END FUNCTION f_coeff


        FUNCTION f_quad( abscX,abscY,wght,q,r,s )
            REAL(KIND(0.D0)), DIMENSION(nb,nnode), INTENT(IN) :: abscX, abscY, wght
            REAL(KIND(0.D0)), INTENT(IN) :: q,r,s
            REAL(KIND(0.D0)) :: f_quad_RV, f_quad
            INTEGER :: i

            f_quad = 0d0
            DO i = 1,nb
                f_quad_RV = SUM( wght(i,:)*(abscX(i,:)**q)*(abscY(i,:)**r) )
                f_quad = f_quad + weight(i)*(R0(i)**s)*f_quad_RV
            END DO

        END FUNCTION f_quad


        FUNCTION f_quad2D( abscX,abscY,wght,pow )
            REAL(KIND(0.D0)), DIMENSION(nnode), INTENT(IN) :: abscX, abscY, wght
            REAL(KIND(0.D0)), DIMENSION(3), INTENT(IN) :: pow
            REAL(KIND(0.D0)) :: f_quad2D

            f_quad2D = SUM( wght(:)*(abscX(:)**pow(1))*(abscY(:)**pow(2)) )
        END FUNCTION f_quad2D



END MODULE m_qbmm
