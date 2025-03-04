!>
!! @file m_viscous.f90
!! @brief Contains module m_viscous
#:include 'macros.fpp'

!> @brief The module contains the subroutines used to compute viscous terms.
module m_viscous

    ! Dependencies =============================================================
    use m_derived_types        !< Definitions of the derived types

    use m_global_parameters    !< Definitions of the global parameters

    use m_weno

    use m_helper
    ! ==========================================================================

    private; public s_get_viscous, &
 s_compute_viscous_stress_tensor, &
 s_initialize_viscous_module, &
 s_reconstruct_cell_boundary_values_visc_deriv, &
 s_compute_viscous_rhs, &
 s_finalize_viscous_module

    type(int_bounds_info) :: iv
    type(int_bounds_info) :: is1, is2, is3
    !$acc declare create(is1, is2, is3, iv)

    real(kind(0d0)), allocatable, dimension(:, :) :: Res
    !$acc declare create(Res)

    !> @name Additional field for capillary source terms
    !> @{
    type(scalar_field), allocatable, dimension(:) :: tau_Re_vf
    !> @}

contains

    subroutine s_initialize_viscous_module()

        integer :: i, j !< generic loop iterators
        type(int_bounds_info) :: ix, iy, iz

        ! Configuring Coordinate Direction Indexes =========================
        ix%beg = -buff_size; iy%beg = 0; iz%beg = 0

        if (n > 0) iy%beg = -buff_size; if (p > 0) iz%beg = -buff_size

        ix%end = m - ix%beg; iy%end = n - iy%beg; iz%end = p - iz%beg
        ! ==================================================================

        @:ALLOCATE(Res(1:2, 1:maxval(Re_size)))

        do i = 1, 2
            do j = 1, Re_size(i)
                Res(i, j) = fluid_pp(Re_idx(i, j))%Re(i)
            end do
        end do
        !$acc update device(Res, Re_idx, Re_size)

        if (cyl_coord) then
            @:ALLOCATE(tau_Re_vf(1:sys_size))
            do i = 1, num_dims
                @:ALLOCATE(tau_Re_vf(cont_idx%end + i)%sf(ix%beg:ix%end, &
                                                       &  iy%beg:iy%end, &
                                                       &  iz%beg:iz%end))
            end do
            @:ALLOCATE(tau_Re_vf(E_idx)%sf(ix%beg:ix%end, &
                                         & iy%beg:iy%end, &
                                         & iz%beg:iz%end))
        end if

    end subroutine s_initialize_viscous_module

    !> The purpose of this subroutine is to compute the viscous
    !      stress tensor for the cells directly next to the axis in
    !      cylindrical coordinates. This is necessary to avoid the
    !      1/r singularity that arises at the cell boundary coinciding
    !      with the axis, i.e., y_cb(-1) = 0.
    !  @param q_prim_vf Cell-average primitive variables
    !  @param grad_x_vf Cell-average primitive variable derivatives, x-dir
    !  @param grad_y_vf Cell-average primitive variable derivatives, y-dir
    !  @param grad_z_vf Cell-average primitive variable derivatives, z-dir
    subroutine s_compute_viscous_stress_tensor(q_prim_vf, grad_x_vf, grad_y_vf, grad_z_vf, &
                                               tau_Re_vf, &
                                               ix, iy, iz) ! ---

        type(scalar_field), dimension(sys_size), intent(IN) :: q_prim_vf
        type(scalar_field), dimension(num_dims), intent(IN) :: grad_x_vf, grad_y_vf, grad_z_vf

        type(scalar_field), dimension(1:sys_size) :: tau_Re_vf

        real(kind(0d0)) :: rho_visc, gamma_visc, pi_inf_visc, alpha_visc_sum  !< Mixture variables
        real(kind(0d0)), dimension(2) :: Re_visc
        real(kind(0d0)), dimension(num_fluids) :: alpha_visc, alpha_rho_visc

        real(kind(0d0)), dimension(num_dims, num_dims) :: tau_Re

        integer :: i, j, k, l, q !< Generic loop iterator

        type(int_bounds_info) :: ix, iy, iz

        !$acc update device(ix, iy, iz)

        !$acc parallel loop collapse(3) gang vector default(present)
        do l = iz%beg, iz%end
            do k = iy%beg, iy%end
                do j = ix%beg, ix%end
                    !$acc loop seq
                    do i = momxb, E_idx
                        tau_Re_vf(i)%sf(j, k, l) = 0d0
                    end do
                end do
            end do
        end do
        if (Re_size(1) > 0) then    ! Shear stresses
            !$acc parallel loop collapse(3) gang vector default(present) private(alpha_visc, alpha_rho_visc, Re_visc, tau_Re )
            do l = iz%beg, iz%end
                do k = -1, 1
                    do j = ix%beg, ix%end

                        !$acc loop seq
                        do i = 1, num_fluids
                            alpha_rho_visc(i) = q_prim_vf(i)%sf(j, k, l)
                            if (bubbles .and. num_fluids == 1) then
                                alpha_visc(i) = 1d0 - q_prim_vf(E_idx + i)%sf(j, k, l)
                            else
                                alpha_visc(i) = q_prim_vf(E_idx + i)%sf(j, k, l)
                            end if
                        end do

                        if (bubbles) then
                            rho_visc = 0d0
                            gamma_visc = 0d0
                            pi_inf_visc = 0d0

                            if (mpp_lim .and. (model_eqns == 2) .and. (num_fluids > 2)) then
                                !$acc loop seq
                                do i = 1, num_fluids
                                    rho_visc = rho_visc + alpha_rho_visc(i)
                                    gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                    pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                                end do
                            else if ((model_eqns == 2) .and. (num_fluids > 2)) then
                                !$acc loop seq
                                do i = 1, num_fluids - 1
                                    rho_visc = rho_visc + alpha_rho_visc(i)
                                    gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                    pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                                end do
                            else
                                rho_visc = alpha_rho_visc(1)
                                gamma_visc = gammas(1)
                                pi_inf_visc = pi_infs(1)
                            end if
                        else
                            rho_visc = 0d0
                            gamma_visc = 0d0
                            pi_inf_visc = 0d0

                            alpha_visc_sum = 0d0

                            if (mpp_lim) then
                                !$acc loop seq
                                do i = 1, num_fluids
                                    alpha_rho_visc(i) = max(0d0, alpha_rho_visc(i))
                                    alpha_visc(i) = min(max(0d0, alpha_visc(i)), 1d0)
                                    alpha_visc_sum = alpha_visc_sum + alpha_visc(i)
                                end do

                                alpha_visc = alpha_visc/max(alpha_visc_sum, sgm_eps)

                            end if

                            !$acc loop seq
                            do i = 1, num_fluids
                                rho_visc = rho_visc + alpha_rho_visc(i)
                                gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                            end do

                            if (any(Re_size > 0)) then
                                !$acc loop seq
                                do i = 1, 2
                                    Re_visc(i) = dflt_real

                                    if (Re_size(i) > 0) Re_visc(i) = 0d0
                                    !$acc loop seq
                                    do q = 1, Re_size(i)
                                        Re_visc(i) = alpha_visc(Re_idx(i, q))/Res(i, q) &
                                                     + Re_visc(i)
                                    end do

                                    Re_visc(i) = 1d0/max(Re_visc(i), sgm_eps)

                                end do
                            end if
                        end if

                        tau_Re(2, 1) = (grad_y_vf(1)%sf(j, k, l) + &
                                        grad_x_vf(2)%sf(j, k, l))/ &
                                       Re_visc(1)

                        tau_Re(2, 2) = (4d0*grad_y_vf(2)%sf(j, k, l) &
                                        - 2d0*grad_x_vf(1)%sf(j, k, l) &
                                        - 2d0*q_prim_vf(momxb + 1)%sf(j, k, l)/y_cc(k))/ &
                                       (3d0*Re_visc(1))
                        !$acc loop seq
                        do i = 1, 2
                            tau_Re_vf(contxe + i)%sf(j, k, l) = &
                                tau_Re_vf(contxe + i)%sf(j, k, l) - &
                                tau_Re(2, i)

                            tau_Re_vf(E_idx)%sf(j, k, l) = &
                                tau_Re_vf(E_idx)%sf(j, k, l) - &
                                q_prim_vf(contxe + i)%sf(j, k, l)*tau_Re(2, i)
                        end do
                    end do
                end do
            end do
        end if

        if (Re_size(2) > 0) then    ! Bulk stresses
            !$acc parallel loop collapse(3) gang vector default(present) private(alpha_visc, alpha_rho_visc, Re_visc, tau_Re )
            do l = iz%beg, iz%end
                do k = -1, 1
                    do j = ix%beg, ix%end

                        !$acc loop seq
                        do i = 1, num_fluids
                            alpha_rho_visc(i) = q_prim_vf(i)%sf(j, k, l)
                            if (bubbles .and. num_fluids == 1) then
                                alpha_visc(i) = 1d0 - q_prim_vf(E_idx + i)%sf(j, k, l)
                            else
                                alpha_visc(i) = q_prim_vf(E_idx + i)%sf(j, k, l)
                            end if
                        end do

                        if (bubbles) then
                            rho_visc = 0d0
                            gamma_visc = 0d0
                            pi_inf_visc = 0d0

                            if (mpp_lim .and. (model_eqns == 2) .and. (num_fluids > 2)) then
                                !$acc loop seq
                                do i = 1, num_fluids
                                    rho_visc = rho_visc + alpha_rho_visc(i)
                                    gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                    pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                                end do
                            else if ((model_eqns == 2) .and. (num_fluids > 2)) then
                                !$acc loop seq
                                do i = 1, num_fluids - 1
                                    rho_visc = rho_visc + alpha_rho_visc(i)
                                    gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                    pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                                end do
                            else
                                rho_visc = alpha_rho_visc(1)
                                gamma_visc = gammas(1)
                                pi_inf_visc = pi_infs(1)
                            end if
                        else
                            rho_visc = 0d0
                            gamma_visc = 0d0
                            pi_inf_visc = 0d0

                            alpha_visc_sum = 0d0

                            if (mpp_lim) then
                                !$acc loop seq
                                do i = 1, num_fluids
                                    alpha_rho_visc(i) = max(0d0, alpha_rho_visc(i))
                                    alpha_visc(i) = min(max(0d0, alpha_visc(i)), 1d0)
                                    alpha_visc_sum = alpha_visc_sum + alpha_visc(i)
                                end do

                                alpha_visc = alpha_visc/max(alpha_visc_sum, sgm_eps)

                            end if

                            !$acc loop seq
                            do i = 1, num_fluids
                                rho_visc = rho_visc + alpha_rho_visc(i)
                                gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                            end do

                            if (any(Re_size > 0)) then
                                !$acc loop seq
                                do i = 1, 2
                                    Re_visc(i) = dflt_real

                                    if (Re_size(i) > 0) Re_visc(i) = 0d0
                                    !$acc loop seq
                                    do q = 1, Re_size(i)
                                        Re_visc(i) = alpha_visc(Re_idx(i, q))/Res(i, q) &
                                                     + Re_visc(i)
                                    end do

                                    Re_visc(i) = 1d0/max(Re_visc(i), sgm_eps)

                                end do
                            end if
                        end if

                        tau_Re(2, 2) = (grad_x_vf(1)%sf(j, k, l) + &
                                        grad_y_vf(2)%sf(j, k, l) + &
                                        q_prim_vf(momxb + 1)%sf(j, k, l)/y_cc(k))/ &
                                       Re_visc(2)

                        tau_Re_vf(momxb + 1)%sf(j, k, l) = &
                            tau_Re_vf(momxb + 1)%sf(j, k, l) - &
                            tau_Re(2, 2)

                        tau_Re_vf(E_idx)%sf(j, k, l) = &
                            tau_Re_vf(E_idx)%sf(j, k, l) - &
                            q_prim_vf(momxb + 1)%sf(j, k, l)*tau_Re(2, 2)

                    end do
                end do
            end do
        end if

        if (p == 0) return

        if (Re_size(1) > 0) then    ! Shear stresses
            !$acc parallel loop collapse(3) gang vector default(present) private(alpha_visc, alpha_rho_visc, Re_visc, tau_Re )
            do l = iz%beg, iz%end
                do k = -1, 1
                    do j = ix%beg, ix%end

                        !$acc loop seq
                        do i = 1, num_fluids
                            alpha_rho_visc(i) = q_prim_vf(i)%sf(j, k, l)
                            if (bubbles .and. num_fluids == 1) then
                                alpha_visc(i) = 1d0 - q_prim_vf(E_idx + i)%sf(j, k, l)
                            else
                                alpha_visc(i) = q_prim_vf(E_idx + i)%sf(j, k, l)
                            end if
                        end do

                        if (bubbles) then
                            rho_visc = 0d0
                            gamma_visc = 0d0
                            pi_inf_visc = 0d0

                            if (mpp_lim .and. (model_eqns == 2) .and. (num_fluids > 2)) then
                                !$acc loop seq
                                do i = 1, num_fluids
                                    rho_visc = rho_visc + alpha_rho_visc(i)
                                    gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                    pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                                end do
                            else if ((model_eqns == 2) .and. (num_fluids > 2)) then
                                !$acc loop seq
                                do i = 1, num_fluids - 1
                                    rho_visc = rho_visc + alpha_rho_visc(i)
                                    gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                    pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                                end do
                            else
                                rho_visc = alpha_rho_visc(1)
                                gamma_visc = gammas(1)
                                pi_inf_visc = pi_infs(1)
                            end if
                        else
                            rho_visc = 0d0
                            gamma_visc = 0d0
                            pi_inf_visc = 0d0

                            alpha_visc_sum = 0d0

                            if (mpp_lim) then
                                !$acc loop seq
                                do i = 1, num_fluids
                                    alpha_rho_visc(i) = max(0d0, alpha_rho_visc(i))
                                    alpha_visc(i) = min(max(0d0, alpha_visc(i)), 1d0)
                                    alpha_visc_sum = alpha_visc_sum + alpha_visc(i)
                                end do

                                alpha_visc = alpha_visc/max(alpha_visc_sum, sgm_eps)

                            end if

                            !$acc loop seq
                            do i = 1, num_fluids
                                rho_visc = rho_visc + alpha_rho_visc(i)
                                gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                            end do

                            if (any(Re_size > 0)) then
                                !$acc loop seq
                                do i = 1, 2
                                    Re_visc(i) = dflt_real

                                    if (Re_size(i) > 0) Re_visc(i) = 0d0
                                    !$acc loop seq
                                    do q = 1, Re_size(i)
                                        Re_visc(i) = alpha_visc(Re_idx(i, q))/Res(i, q) &
                                                     + Re_visc(i)
                                    end do

                                    Re_visc(i) = 1d0/max(Re_visc(i), sgm_eps)

                                end do
                            end if
                        end if

                        tau_Re(2, 2) = -(2d0/3d0)*grad_z_vf(3)%sf(j, k, l)/y_cc(k)/ &
                                       Re_visc(1)

                        tau_Re(2, 3) = ((grad_z_vf(2)%sf(j, k, l) - &
                                         q_prim_vf(momxe)%sf(j, k, l))/ &
                                        y_cc(k) + grad_y_vf(3)%sf(j, k, l))/ &
                                       Re_visc(1)

                        !$acc loop seq
                        do i = 2, 3
                            tau_Re_vf(contxe + i)%sf(j, k, l) = &
                                tau_Re_vf(contxe + i)%sf(j, k, l) - &
                                tau_Re(2, i)

                            tau_Re_vf(E_idx)%sf(j, k, l) = &
                                tau_Re_vf(E_idx)%sf(j, k, l) - &
                                q_prim_vf(contxe + i)%sf(j, k, l)*tau_Re(2, i)
                        end do

                    end do
                end do
            end do
        end if

        if (Re_size(2) > 0) then    ! Bulk stresses
            !$acc parallel loop collapse(3) gang vector default(present) private(alpha_visc, alpha_rho_visc, Re_visc, tau_Re )
            do l = iz%beg, iz%end
                do k = -1, 1
                    do j = ix%beg, ix%end

                        !$acc loop seq
                        do i = 1, num_fluids
                            alpha_rho_visc(i) = q_prim_vf(i)%sf(j, k, l)
                            if (bubbles .and. num_fluids == 1) then
                                alpha_visc(i) = 1d0 - q_prim_vf(E_idx + i)%sf(j, k, l)
                            else
                                alpha_visc(i) = q_prim_vf(E_idx + i)%sf(j, k, l)
                            end if
                        end do

                        if (bubbles) then
                            rho_visc = 0d0
                            gamma_visc = 0d0
                            pi_inf_visc = 0d0

                            if (mpp_lim .and. (model_eqns == 2) .and. (num_fluids > 2)) then
                                !$acc loop seq
                                do i = 1, num_fluids
                                    rho_visc = rho_visc + alpha_rho_visc(i)
                                    gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                    pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                                end do
                            else if ((model_eqns == 2) .and. (num_fluids > 2)) then
                                !$acc loop seq
                                do i = 1, num_fluids - 1
                                    rho_visc = rho_visc + alpha_rho_visc(i)
                                    gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                    pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                                end do
                            else
                                rho_visc = alpha_rho_visc(1)
                                gamma_visc = gammas(1)
                                pi_inf_visc = pi_infs(1)
                            end if
                        else
                            rho_visc = 0d0
                            gamma_visc = 0d0
                            pi_inf_visc = 0d0

                            alpha_visc_sum = 0d0

                            if (mpp_lim) then
                                !$acc loop seq
                                do i = 1, num_fluids
                                    alpha_rho_visc(i) = max(0d0, alpha_rho_visc(i))
                                    alpha_visc(i) = min(max(0d0, alpha_visc(i)), 1d0)
                                    alpha_visc_sum = alpha_visc_sum + alpha_visc(i)
                                end do

                                alpha_visc = alpha_visc/max(alpha_visc_sum, sgm_eps)

                            end if

                            !$acc loop seq
                            do i = 1, num_fluids
                                rho_visc = rho_visc + alpha_rho_visc(i)
                                gamma_visc = gamma_visc + alpha_visc(i)*gammas(i)
                                pi_inf_visc = pi_inf_visc + alpha_visc(i)*pi_infs(i)
                            end do

                            if (any(Re_size > 0)) then
                                !$acc loop seq
                                do i = 1, 2
                                    Re_visc(i) = dflt_real

                                    if (Re_size(i) > 0) Re_visc(i) = 0d0
                                    !$acc loop seq
                                    do q = 1, Re_size(i)
                                        Re_visc(i) = alpha_visc(Re_idx(i, q))/Res(i, q) &
                                                     + Re_visc(i)
                                    end do

                                    Re_visc(i) = 1d0/max(Re_visc(i), sgm_eps)

                                end do
                            end if
                        end if

                        tau_Re(2, 2) = grad_z_vf(3)%sf(j, k, l)/y_cc(k)/ &
                                       Re_visc(2)

                        tau_Re_vf(momxb + 1)%sf(j, k, l) = &
                            tau_Re_vf(momxb + 1)%sf(j, k, l) - &
                            tau_Re(2, 2)

                        tau_Re_vf(E_idx)%sf(j, k, l) = &
                            tau_Re_vf(E_idx)%sf(j, k, l) - &
                            q_prim_vf(momxb + 1)%sf(j, k, l)*tau_Re(2, 2)

                    end do
                end do
            end do
        end if
    end subroutine s_compute_viscous_stress_tensor ! ----------------------------------------

!>  Computes viscous terms
    !!  @param q_cons_vf Cell-averaged conservative variables
    !!  @param q_prim_vf Cell-averaged primitive variables
    !!  @param rhs_vf Cell-averaged RHS variables
    subroutine s_get_viscous(qL_prim_rsx_vf, qL_prim_rsy_vf, qL_prim_rsz_vf, &
                             dqL_prim_dx_n, dqL_prim_dy_n, dqL_prim_dz_n, &
                             qL_prim, &
                             qR_prim_rsx_vf, qR_prim_rsy_vf, qR_prim_rsz_vf, &
                             dqR_prim_dx_n, dqR_prim_dy_n, dqR_prim_dz_n, &
                             qR_prim, &
                             q_prim_qp, &
                             dq_prim_dx_qp, dq_prim_dy_qp, dq_prim_dz_qp, &
                             ix, iy, iz)

        real(kind(0d0)), dimension(startx:, starty:, startz:, 1:), &
            intent(INOUT) :: qL_prim_rsx_vf, qR_prim_rsx_vf, &
                             qL_prim_rsy_vf, qR_prim_rsy_vf, &
                             qL_prim_rsz_vf, qR_prim_rsz_vf

        type(vector_field), dimension(1:num_dims) :: qL_prim, qR_prim

        type(vector_field) :: q_prim_qp

        type(vector_field), dimension(1:num_dims), &
            intent(INOUT) :: dqL_prim_dx_n, dqR_prim_dx_n, &
                             dqL_prim_dy_n, dqR_prim_dy_n, &
                             dqL_prim_dz_n, dqR_prim_dz_n

        type(vector_field) :: dq_prim_dx_qp, dq_prim_dy_qp, dq_prim_dz_qp

        type(int_bounds_info), intent(IN) :: ix, iy, iz

        integer :: i, j, k, l

        do i = 1, num_dims

            iv%beg = mom_idx%beg; iv%end = mom_idx%end

            !$acc update device(iv)

            call s_reconstruct_cell_boundary_values_visc( &
                q_prim_qp%vf(iv%beg:iv%end), &
                qL_prim_rsx_vf, qL_prim_rsy_vf, qL_prim_rsz_vf, &
                qR_prim_rsx_vf, qR_prim_rsy_vf, qR_prim_rsz_vf, &
                i, qL_prim(i)%vf(iv%beg:iv%end), qR_prim(i)%vf(iv%beg:iv%end), &
                ix, iy, iz)
        end do

        if (weno_Re_flux) then
            ! Compute velocity gradient at cell centers using scalar
            ! divergence theorem
            do i = 1, num_dims
                if (i == 1) then
                    call s_apply_scalar_divergence_theorem( &
                        qL_prim(i)%vf(iv%beg:iv%end), &
                        qR_prim(i)%vf(iv%beg:iv%end), &
                        dq_prim_dx_qp%vf(iv%beg:iv%end), i, &
                        ix, iy, iz, iv, dx, m, buff_size)
                elseif (i == 2) then
                    call s_apply_scalar_divergence_theorem( &
                        qL_prim(i)%vf(iv%beg:iv%end), &
                        qR_prim(i)%vf(iv%beg:iv%end), &
                        dq_prim_dy_qp%vf(iv%beg:iv%end), i, &
                        ix, iy, iz, iv, dy, n, buff_size)
                else
                    call s_apply_scalar_divergence_theorem( &
                        qL_prim(i)%vf(iv%beg:iv%end), &
                        qR_prim(i)%vf(iv%beg:iv%end), &
                        dq_prim_dz_qp%vf(iv%beg:iv%end), i, &
                        ix, iy, iz, iv, dz, p, buff_size)
                end if
            end do

        else ! Compute velocity gradient at cell centers using finite differences

            iv%beg = mom_idx%beg; iv%end = mom_idx%end
            !$acc update device(iv)

            !$acc parallel loop collapse(3) gang vector default(present)
            do l = iz%beg, iz%end
                do k = iy%beg, iy%end
                    do j = ix%beg + 1, ix%end
                        !$acc loop seq
                        do i = iv%beg, iv%end
                            dqL_prim_dx_n(1)%vf(i)%sf(j, k, l) = &
                                (q_prim_qp%vf(i)%sf(j, k, l) - &
                                 q_prim_qp%vf(i)%sf(j - 1, k, l))/ &
                                (x_cc(j) - x_cc(j - 1))
                        end do
                    end do
                end do
            end do

            !$acc parallel loop collapse(3) gang vector default(present)
            do l = iz%beg, iz%end
                do k = iy%beg, iy%end
                    do j = ix%beg, ix%end - 1
                        !$acc loop seq
                        do i = iv%beg, iv%end
                            dqR_prim_dx_n(1)%vf(i)%sf(j, k, l) = &
                                (q_prim_qp%vf(i)%sf(j + 1, k, l) - &
                                 q_prim_qp%vf(i)%sf(j, k, l))/ &
                                (x_cc(j + 1) - x_cc(j))
                        end do
                    end do
                end do
            end do

            if (n > 0) then

                !$acc parallel loop collapse(3) gang vector default(present)
                do l = iz%beg, iz%end
                    do j = iy%beg + 1, iy%end
                        do k = ix%beg, ix%end
                            !$acc loop seq
                            do i = iv%beg, iv%end
                                dqL_prim_dy_n(2)%vf(i)%sf(k, j, l) = &
                                    (q_prim_qp%vf(i)%sf(k, j, l) - &
                                     q_prim_qp%vf(i)%sf(k, j - 1, l))/ &
                                    (y_cc(j) - y_cc(j - 1))
                            end do
                        end do
                    end do
                end do

                !$acc parallel loop collapse(3) gang vector default(present)
                do l = iz%beg, iz%end
                    do j = iy%beg, iy%end - 1
                        do k = ix%beg, ix%end
                            !$acc loop seq
                            do i = iv%beg, iv%end
                                dqR_prim_dy_n(2)%vf(i)%sf(k, j, l) = &
                                    (q_prim_qp%vf(i)%sf(k, j + 1, l) - &
                                     q_prim_qp%vf(i)%sf(k, j, l))/ &
                                    (y_cc(j + 1) - y_cc(j))
                            end do
                        end do
                    end do
                end do

                !$acc parallel loop collapse(3) gang vector default(present)
                do l = iz%beg, iz%end
                    do j = iy%beg + 1, iy%end
                        do k = ix%beg + 1, ix%end - 1
                            !$acc loop seq
                            do i = iv%beg, iv%end
                                dqL_prim_dx_n(2)%vf(i)%sf(k, j, l) = &
                                    (dqL_prim_dx_n(1)%vf(i)%sf(k, j, l) + &
                                     dqR_prim_dx_n(1)%vf(i)%sf(k, j, l) + &
                                     dqL_prim_dx_n(1)%vf(i)%sf(k, j - 1, l) + &
                                     dqR_prim_dx_n(1)%vf(i)%sf(k, j - 1, l))

                                dqL_prim_dx_n(2)%vf(i)%sf(k, j, l) = 25d-2* &
                                                                     dqL_prim_dx_n(2)%vf(i)%sf(k, j, l)
                            end do
                        end do
                    end do
                end do

                !$acc parallel loop collapse(3) gang vector default(present)
                do l = iz%beg, iz%end
                    do j = iy%beg, iy%end - 1
                        do k = ix%beg + 1, ix%end - 1
                            !$acc loop seq
                            do i = iv%beg, iv%end
                                dqR_prim_dx_n(2)%vf(i)%sf(k, j, l) = &
                                    (dqL_prim_dx_n(1)%vf(i)%sf(k, j + 1, l) + &
                                     dqR_prim_dx_n(1)%vf(i)%sf(k, j + 1, l) + &
                                     dqL_prim_dx_n(1)%vf(i)%sf(k, j, l) + &
                                     dqR_prim_dx_n(1)%vf(i)%sf(k, j, l))

                                dqR_prim_dx_n(2)%vf(i)%sf(k, j, l) = 25d-2* &
                                                                     dqR_prim_dx_n(2)%vf(i)%sf(k, j, l)

                            end do
                        end do
                    end do
                end do

                !$acc parallel loop collapse(3) gang vector default(present)
                do l = iz%beg, iz%end
                    do k = iy%beg + 1, iy%end - 1
                        do j = ix%beg + 1, ix%end
                            !$acc loop seq
                            do i = iv%beg, iv%end
                                dqL_prim_dy_n(1)%vf(i)%sf(j, k, l) = &
                                    (dqL_prim_dy_n(2)%vf(i)%sf(j, k, l) + &
                                     dqR_prim_dy_n(2)%vf(i)%sf(j, k, l) + &
                                     dqL_prim_dy_n(2)%vf(i)%sf(j - 1, k, l) + &
                                     dqR_prim_dy_n(2)%vf(i)%sf(j - 1, k, l))

                                dqL_prim_dy_n(1)%vf(i)%sf(j, k, l) = 25d-2* &
                                                                     dqL_prim_dy_n(1)%vf(i)%sf(j, k, l)

                            end do
                        end do
                    end do
                end do

                !$acc parallel loop collapse(3) gang vector default(present)
                do l = iz%beg, iz%end
                    do k = iy%beg + 1, iy%end - 1
                        do j = ix%beg, ix%end - 1
                            !$acc loop seq
                            do i = iv%beg, iv%end
                                dqR_prim_dy_n(1)%vf(i)%sf(j, k, l) = &
                                    (dqL_prim_dy_n(2)%vf(i)%sf(j + 1, k, l) + &
                                     dqR_prim_dy_n(2)%vf(i)%sf(j + 1, k, l) + &
                                     dqL_prim_dy_n(2)%vf(i)%sf(j, k, l) + &
                                     dqR_prim_dy_n(2)%vf(i)%sf(j, k, l))

                                dqR_prim_dy_n(1)%vf(i)%sf(j, k, l) = 25d-2* &
                                                                     dqR_prim_dy_n(1)%vf(i)%sf(j, k, l)

                            end do
                        end do
                    end do
                end do

                if (p > 0) then

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do j = iz%beg + 1, iz%end
                        do l = iy%beg, iy%end
                            do k = ix%beg, ix%end
                                !$acc loop seq
                                do i = iv%beg, iv%end

                                    dqL_prim_dz_n(3)%vf(i)%sf(k, l, j) = &
                                        (q_prim_qp%vf(i)%sf(k, l, j) - &
                                         q_prim_qp%vf(i)%sf(k, l, j - 1))/ &
                                        (z_cc(j) - z_cc(j - 1))
                                end do
                            end do
                        end do
                    end do

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do j = iz%beg, iz%end - 1
                        do l = iy%beg, iy%end
                            do k = ix%beg, ix%end
                                !$acc loop seq
                                do i = iv%beg, iv%end

                                    dqR_prim_dz_n(3)%vf(i)%sf(k, l, j) = &
                                        (q_prim_qp%vf(i)%sf(k, l, j + 1) - &
                                         q_prim_qp%vf(i)%sf(k, l, j))/ &
                                        (z_cc(j + 1) - z_cc(j))
                                end do
                            end do
                        end do
                    end do

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do l = iz%beg + 1, iz%end - 1
                        do k = iy%beg, iy%end
                            do j = ix%beg + 1, ix%end
                                !$acc loop seq
                                do i = iv%beg, iv%end

                                    dqL_prim_dz_n(1)%vf(i)%sf(j, k, l) = &
                                        (dqL_prim_dz_n(3)%vf(i)%sf(j, k, l) + &
                                         dqR_prim_dz_n(3)%vf(i)%sf(j, k, l) + &
                                         dqL_prim_dz_n(3)%vf(i)%sf(j - 1, k, l) + &
                                         dqR_prim_dz_n(3)%vf(i)%sf(j - 1, k, l))

                                    dqL_prim_dz_n(1)%vf(i)%sf(j, k, l) = 25d-2* &
                                                                         dqL_prim_dz_n(1)%vf(i)%sf(j, k, l)

                                end do
                            end do
                        end do
                    end do

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do l = iz%beg + 1, iz%end - 1
                        do k = iy%beg, iy%end
                            do j = ix%beg, ix%end - 1
                                !$acc loop seq
                                do i = iv%beg, iv%end

                                    dqR_prim_dz_n(1)%vf(i)%sf(j, k, l) = &
                                        (dqL_prim_dz_n(3)%vf(i)%sf(j + 1, k, l) + &
                                         dqR_prim_dz_n(3)%vf(i)%sf(j + 1, k, l) + &
                                         dqL_prim_dz_n(3)%vf(i)%sf(j, k, l) + &
                                         dqR_prim_dz_n(3)%vf(i)%sf(j, k, l))

                                    dqR_prim_dz_n(1)%vf(i)%sf(j, k, l) = 25d-2* &
                                                                         dqR_prim_dz_n(1)%vf(i)%sf(j, k, l)

                                end do
                            end do
                        end do
                    end do

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do l = iz%beg + 1, iz%end - 1
                        do j = iy%beg + 1, iy%end
                            do k = ix%beg, ix%end
                                !$acc loop seq
                                do i = iv%beg, iv%end

                                    dqL_prim_dz_n(2)%vf(i)%sf(k, j, l) = &
                                        (dqL_prim_dz_n(3)%vf(i)%sf(k, j, l) + &
                                         dqR_prim_dz_n(3)%vf(i)%sf(k, j, l) + &
                                         dqL_prim_dz_n(3)%vf(i)%sf(k, j - 1, l) + &
                                         dqR_prim_dz_n(3)%vf(i)%sf(k, j - 1, l))

                                    dqL_prim_dz_n(2)%vf(i)%sf(k, j, l) = 25d-2* &
                                                                         dqL_prim_dz_n(2)%vf(i)%sf(k, j, l)

                                end do
                            end do
                        end do
                    end do

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do l = iz%beg + 1, iz%end - 1
                        do j = iy%beg, iy%end - 1
                            do k = ix%beg, ix%end
                                !$acc loop seq
                                do i = iv%beg, iv%end

                                    dqR_prim_dz_n(2)%vf(i)%sf(k, j, l) = &
                                        (dqL_prim_dz_n(3)%vf(i)%sf(k, j + 1, l) + &
                                         dqR_prim_dz_n(3)%vf(i)%sf(k, j + 1, l) + &
                                         dqL_prim_dz_n(3)%vf(i)%sf(k, j, l) + &
                                         dqR_prim_dz_n(3)%vf(i)%sf(k, j, l))

                                    dqR_prim_dz_n(2)%vf(i)%sf(k, j, l) = 25d-2* &
                                                                         dqR_prim_dz_n(2)%vf(i)%sf(k, j, l)

                                end do
                            end do
                        end do
                    end do

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do j = iz%beg + 1, iz%end
                        do l = iy%beg + 1, iy%end - 1
                            do k = ix%beg, ix%end
                                !$acc loop seq
                                do i = iv%beg, iv%end

                                    dqL_prim_dy_n(3)%vf(i)%sf(k, l, j) = &
                                        (dqL_prim_dy_n(2)%vf(i)%sf(k, l, j) + &
                                         dqR_prim_dy_n(2)%vf(i)%sf(k, l, j) + &
                                         dqL_prim_dy_n(2)%vf(i)%sf(k, l, j - 1) + &
                                         dqR_prim_dy_n(2)%vf(i)%sf(k, l, j - 1))

                                    dqL_prim_dy_n(3)%vf(i)%sf(k, l, j) = 25d-2* &
                                                                         dqL_prim_dy_n(3)%vf(i)%sf(k, l, j)

                                end do
                            end do
                        end do
                    end do

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do j = iz%beg, iz%end - 1
                        do l = iy%beg + 1, iy%end - 1
                            do k = ix%beg, ix%end
                                !$acc loop seq
                                do i = iv%beg, iv%end

                                    dqR_prim_dy_n(3)%vf(i)%sf(k, l, j) = &
                                        (dqL_prim_dy_n(2)%vf(i)%sf(k, l, j + 1) + &
                                         dqR_prim_dy_n(2)%vf(i)%sf(k, l, j + 1) + &
                                         dqL_prim_dy_n(2)%vf(i)%sf(k, l, j) + &
                                         dqR_prim_dy_n(2)%vf(i)%sf(k, l, j))

                                    dqR_prim_dy_n(3)%vf(i)%sf(k, l, j) = 25d-2* &
                                                                         dqR_prim_dy_n(3)%vf(i)%sf(k, l, j)

                                end do
                            end do
                        end do
                    end do

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do j = iz%beg + 1, iz%end
                        do l = iy%beg, iy%end
                            do k = ix%beg + 1, ix%end - 1
                                !$acc loop seq
                                do i = iv%beg, iv%end

                                    dqL_prim_dx_n(3)%vf(i)%sf(k, l, j) = &
                                        (dqL_prim_dx_n(1)%vf(i)%sf(k, l, j) + &
                                         dqR_prim_dx_n(1)%vf(i)%sf(k, l, j) + &
                                         dqL_prim_dx_n(1)%vf(i)%sf(k, l, j - 1) + &
                                         dqR_prim_dx_n(1)%vf(i)%sf(k, l, j - 1))

                                    dqL_prim_dx_n(3)%vf(i)%sf(k, l, j) = 25d-2* &
                                                                         dqL_prim_dx_n(3)%vf(i)%sf(k, l, j)

                                end do
                            end do
                        end do
                    end do

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do j = iz%beg, iz%end - 1
                        do l = iy%beg, iy%end
                            do k = ix%beg + 1, ix%end - 1
                                !$acc loop seq
                                do i = iv%beg, iv%end
                                    dqR_prim_dx_n(3)%vf(i)%sf(k, l, j) = &
                                        (dqL_prim_dx_n(1)%vf(i)%sf(k, l, j + 1) + &
                                         dqR_prim_dx_n(1)%vf(i)%sf(k, l, j + 1) + &
                                         dqL_prim_dx_n(1)%vf(i)%sf(k, l, j) + &
                                         dqR_prim_dx_n(1)%vf(i)%sf(k, l, j))

                                    dqR_prim_dx_n(3)%vf(i)%sf(k, l, j) = 25d-2* &
                                                                         dqR_prim_dx_n(3)%vf(i)%sf(k, l, j)

                                end do
                            end do
                        end do
                    end do

                    do i = iv%beg, iv%end
                        call s_compute_fd_gradient(q_prim_qp%vf(i), &
                                                   dq_prim_dx_qp%vf(i), &
                                                   dq_prim_dy_qp%vf(i), &
                                                   dq_prim_dz_qp%vf(i), &
                                                   ix, iy, iz, buff_size)
                    end do

                else

                    do i = iv%beg, iv%end
                        call s_compute_fd_gradient(q_prim_qp%vf(i), &
                                                   dq_prim_dx_qp%vf(i), &
                                                   dq_prim_dy_qp%vf(i), &
                                                   dq_prim_dy_qp%vf(i), &
                                                   ix, iy, iz, buff_size)
                    end do

                end if

            else
                do i = iv%beg, iv%end
                    call s_compute_fd_gradient(q_prim_qp%vf(i), &
                                               dq_prim_dx_qp%vf(i), &
                                               dq_prim_dx_qp%vf(i), &
                                               dq_prim_dx_qp%vf(i), &
                                               ix, iy, iz, buff_size)
                end do

            end if

        end if

    end subroutine s_get_viscous

    subroutine s_compute_viscous_rhs(idir, q_prim_vf, rhs_vf, flux_src_n, &
                                     dq_prim_dx_vf, dq_prim_dy_vf, dq_prim_dz_vf, ixt, iyt, izt)

        type(scalar_field), dimension(sys_size), intent(IN) :: q_prim_vf, &
                                                               flux_src_n, &
                                                               dq_prim_dx_vf, &
                                                               dq_prim_dy_vf, &
                                                               dq_prim_dz_vf
        type(scalar_field), dimension(sys_size), intent(INOUT) :: rhs_vf
        type(int_bounds_info) :: ixt, iyt, izt
        integer, intent(IN) :: idir
        integer :: i, j, k, l, q

        if (idir == 1) then ! x-direction

            !$acc parallel loop collapse(3) gang vector default(present)
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        !$acc loop seq
                        do i = momxb, E_idx
                            rhs_vf(i)%sf(j, k, l) = &
                                rhs_vf(i)%sf(j, k, l) + 1d0/dx(j)* &
                                (flux_src_n(i)%sf(j - 1, k, l) &
                                 - flux_src_n(i)%sf(j, k, l))
                        end do
                    end do
                end do
            end do

        elseif (idir == 2) then ! y-direction

            if (cyl_coord .and. ((bc_y%beg == -2) .or. (bc_y%beg == -14))) then
                if (p > 0) then
                    call s_compute_viscous_stress_tensor(q_prim_vf, &
                                                         dq_prim_dx_vf(mom_idx%beg:mom_idx%end), &
                                                         dq_prim_dy_vf(mom_idx%beg:mom_idx%end), &
                                                         dq_prim_dz_vf(mom_idx%beg:mom_idx%end), &
                                                         tau_Re_vf, &
                                                         ixt, iyt, izt)
                else
                    call s_compute_viscous_stress_tensor(q_prim_vf, &
                                                         dq_prim_dx_vf(mom_idx%beg:mom_idx%end), &
                                                         dq_prim_dy_vf(mom_idx%beg:mom_idx%end), &
                                                         dq_prim_dy_vf(mom_idx%beg:mom_idx%end), &
                                                         tau_Re_vf, &
                                                         ixt, iyt, izt)
                end if

                !$acc parallel loop collapse(3) gang vector default(present)
                do l = 0, p
                    do k = 1, n
                        do j = 0, m
                            !$acc loop seq
                            do i = momxb, E_idx
                                rhs_vf(i)%sf(j, k, l) = &
                                    rhs_vf(i)%sf(j, k, l) + 1d0/dy(k)* &
                                    (flux_src_n(i)%sf(j, k - 1, l) &
                                     - flux_src_n(i)%sf(j, k, l))
                            end do
                        end do
                    end do
                end do

                !$acc parallel loop collapse(2) gang vector default(present)
                do l = 0, p
                    do j = 0, m
                        !$acc loop seq
                        do i = momxb, E_idx
                            rhs_vf(i)%sf(j, 0, l) = &
                                rhs_vf(i)%sf(j, 0, l) + 1d0/(y_cc(1) - y_cc(-1))* &
                                (tau_Re_vf(i)%sf(j, -1, l) &
                                 - tau_Re_vf(i)%sf(j, 1, l))
                        end do
                    end do
                end do
            else
                !$acc parallel loop collapse(3) gang vector default(present)
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            !$acc loop seq
                            do i = momxb, E_idx
                                rhs_vf(i)%sf(j, k, l) = &
                                    rhs_vf(i)%sf(j, k, l) + 1d0/dy(k)* &
                                    (flux_src_n(i)%sf(j, k - 1, l) &
                                     - flux_src_n(i)%sf(j, k, l))
                            end do
                        end do
                    end do
                end do
            end if

            ! Applying the geometrical viscous Riemann source fluxes calculated as average
            ! of values at cell boundaries
            if (cyl_coord) then
                if ((bc_y%beg == -2) .or. (bc_y%beg == -14)) then

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do l = 0, p
                        do k = 1, n
                            do j = 0, m
                                !$acc loop seq
                                do i = momxb, E_idx
                                    rhs_vf(i)%sf(j, k, l) = &
                                        rhs_vf(i)%sf(j, k, l) - 5d-1/y_cc(k)* &
                                        (flux_src_n(i)%sf(j, k - 1, l) &
                                         + flux_src_n(i)%sf(j, k, l))
                                end do
                            end do
                        end do
                    end do

                    !$acc parallel loop collapse(2) gang vector default(present)
                    do l = 0, p
                        do j = 0, m
                            !$acc loop seq
                            do i = momxb, E_idx
                                rhs_vf(i)%sf(j, 0, l) = &
                                    rhs_vf(i)%sf(j, 0, l) - 1d0/y_cc(0)* &
                                    tau_Re_vf(i)%sf(j, 0, l)
                            end do
                        end do
                    end do

                else

                    !$acc parallel loop collapse(3) gang vector default(present)
                    do l = 0, p
                        do k = 0, n
                            do j = 0, m
                                !$acc loop seq
                                do i = momxb, E_idx
                                    rhs_vf(i)%sf(j, k, l) = &
                                        rhs_vf(i)%sf(j, k, l) - 5d-1/y_cc(k)* &
                                        (flux_src_n(i)%sf(j, k - 1, l) &
                                         + flux_src_n(i)%sf(j, k, l))
                                end do
                            end do
                        end do
                    end do

                end if
            end if

        elseif (idir == 3) then ! z-direction

            !$acc parallel loop collapse(3) gang vector default(present)
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        !$acc loop seq
                        do i = momxb, E_idx
                            rhs_vf(i)%sf(j, k, l) = &
                                rhs_vf(i)%sf(j, k, l) + 1d0/dz(l)* &
                                (flux_src_n(i)%sf(j, k, l - 1) &
                                 - flux_src_n(i)%sf(j, k, l))
                        end do
                    end do
                end do
            end do

            if (grid_geometry == 3) then
                !$acc parallel loop collapse(3) gang vector default(present)
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            rhs_vf(momxb + 1)%sf(j, k, l) = &
                                rhs_vf(momxb + 1)%sf(j, k, l) + 5d-1* &
                                (flux_src_n(momxe)%sf(j, k, l - 1) &
                                 + flux_src_n(momxe)%sf(j, k, l))

                            rhs_vf(momxe)%sf(j, k, l) = &
                                rhs_vf(momxe)%sf(j, k, l) - 5d-1* &
                                (flux_src_n(momxb + 1)%sf(j, k, l - 1) &
                                 + flux_src_n(momxb + 1)%sf(j, k, l))
                        end do
                    end do
                end do
            end if
        end if

    end subroutine s_compute_viscous_rhs

    subroutine s_reconstruct_cell_boundary_values_visc(v_vf, vL_x, vL_y, vL_z, vR_x, vR_y, vR_z, & ! -
                                                       norm_dir, vL_prim_vf, vR_prim_vf, ix, iy, iz)

        type(scalar_field), dimension(iv%beg:iv%end), intent(IN) :: v_vf
        type(scalar_field), dimension(iv%beg:iv%end), intent(INOUT) :: vL_prim_vf, vR_prim_vf

        real(kind(0d0)), dimension(startx:, starty:, startz:, 1:), intent(INOUT) :: vL_x, vL_y, vL_z, vR_x, vR_y, vR_z

        integer, intent(IN) :: norm_dir

        integer :: weno_dir !< Coordinate direction of the WENO reconstruction

        integer :: i, j, k, l

        type(int_bounds_info) :: ix, iy, iz
        ! Reconstruction in s1-direction ===================================

        if (norm_dir == 1) then
            is1 = ix; is2 = iy; is3 = iz
            weno_dir = 1; is1%beg = is1%beg + weno_polyn
            is1%end = is1%end - weno_polyn

        elseif (norm_dir == 2) then
            is1 = iy; is2 = ix; is3 = iz
            weno_dir = 2; is1%beg = is1%beg + weno_polyn
            is1%end = is1%end - weno_polyn

        else
            is1 = iz; is2 = iy; is3 = ix
            weno_dir = 3; is1%beg = is1%beg + weno_polyn
            is1%end = is1%end - weno_polyn

        end if

        !$acc update device(is1, is2, is3, iv)

        if (n > 0) then
            if (p > 0) then

                call s_weno(v_vf(iv%beg:iv%end), &
                            vL_x(:, :, :, iv%beg:iv%end), vL_y(:, :, :, iv%beg:iv%end), vL_z(:, :, :, iv%beg:iv%end), vR_x(:, :, :, iv%beg:iv%end), vR_y(:, :, :, iv%beg:iv%end), vR_z(:, :, :, iv%beg:iv%end), &
                            norm_dir, weno_dir, &
                            is1, is2, is3)
            else
                call s_weno(v_vf(iv%beg:iv%end), &
                            vL_x(:, :, :, iv%beg:iv%end), vL_y(:, :, :, iv%beg:iv%end), vL_z(:, :, :, :), vR_x(:, :, :, iv%beg:iv%end), vR_y(:, :, :, iv%beg:iv%end), vR_z(:, :, :, :), &
                            norm_dir, weno_dir, &
                            is1, is2, is3)
            end if
        else

            call s_weno(v_vf(iv%beg:iv%end), &
                        vL_x(:, :, :, iv%beg:iv%end), vL_y(:, :, :, :), vL_z(:, :, :, :), vR_x(:, :, :, iv%beg:iv%end), vR_y(:, :, :, :), vR_z(:, :, :, :), &
                        norm_dir, weno_dir, &
                        is1, is2, is3)
        end if

        if (any(Re_size > 0)) then
            if (weno_Re_flux) then
                if (norm_dir == 2) then
                    !$acc parallel loop collapse(4) gang vector default(present)
                    do i = iv%beg, iv%end
                        do l = is3%beg, is3%end
                            do j = is1%beg, is1%end
                                do k = is2%beg, is2%end
                                    vL_prim_vf(i)%sf(k, j, l) = vL_y(j, k, l, i)
                                    vR_prim_vf(i)%sf(k, j, l) = vR_y(j, k, l, i)
                                end do
                            end do
                        end do
                    end do
                elseif (norm_dir == 3) then
                    !$acc parallel loop collapse(4) gang vector default(present)
                    do i = iv%beg, iv%end
                        do j = is1%beg, is1%end
                            do k = is2%beg, is2%end
                                do l = is3%beg, is3%end
                                    vL_prim_vf(i)%sf(l, k, j) = vL_z(j, k, l, i)
                                    vR_prim_vf(i)%sf(l, k, j) = vR_z(j, k, l, i)
                                end do
                            end do
                        end do
                    end do
                elseif (norm_dir == 1) then
                    !$acc parallel loop collapse(4) gang vector default(present)
                    do i = iv%beg, iv%end
                        do l = is3%beg, is3%end
                            do k = is2%beg, is2%end
                                do j = is1%beg, is1%end
                                    vL_prim_vf(i)%sf(j, k, l) = vL_x(j, k, l, i)
                                    vR_prim_vf(i)%sf(j, k, l) = vR_x(j, k, l, i)
                                end do
                            end do
                        end do
                    end do
                end if
            end if
        end if

        ! ==================================================================

    end subroutine s_reconstruct_cell_boundary_values_visc ! --------------------

    subroutine s_reconstruct_cell_boundary_values_visc_deriv(v_vf, vL_x, vL_y, vL_z, vR_x, vR_y, vR_z, & ! -
                                                             norm_dir, vL_prim_vf, vR_prim_vf, ix, iy, iz)

        type(scalar_field), dimension(iv%beg:iv%end), intent(IN) :: v_vf
        type(scalar_field), dimension(iv%beg:iv%end), intent(INOUT) :: vL_prim_vf, vR_prim_vf

        type(int_bounds_info) :: ix, iy, iz

        real(kind(0d0)), dimension(startx:, starty:, startz:, iv%beg:), intent(INOUT) :: vL_x, vL_y, vL_z, vR_x, vR_y, vR_z

        integer, intent(IN) :: norm_dir

        integer :: weno_dir !< Coordinate direction of the WENO reconstruction

        integer :: i, j, k, l
        ! Reconstruction in s1-direction ===================================

        if (norm_dir == 1) then
            is1 = ix; is2 = iy; is3 = iz
            weno_dir = 1; is1%beg = is1%beg + weno_polyn
            is1%end = is1%end - weno_polyn

        elseif (norm_dir == 2) then
            is1 = iy; is2 = ix; is3 = iz
            weno_dir = 2; is1%beg = is1%beg + weno_polyn
            is1%end = is1%end - weno_polyn

        else
            is1 = iz; is2 = iy; is3 = ix
            weno_dir = 3; is1%beg = is1%beg + weno_polyn
            is1%end = is1%end - weno_polyn

        end if

        !$acc update device(is1, is2, is3, iv)

        if (n > 0) then
            if (p > 0) then

                call s_weno(v_vf(iv%beg:iv%end), &
                            vL_x(:, :, :, iv%beg:iv%end), vL_y(:, :, :, iv%beg:iv%end), vL_z(:, :, :, iv%beg:iv%end), vR_x(:, :, :, iv%beg:iv%end), vR_y(:, :, :, iv%beg:iv%end), vR_z(:, :, :, iv%beg:iv%end), &
                            norm_dir, weno_dir, &
                            is1, is2, is3)
            else
                call s_weno(v_vf(iv%beg:iv%end), &
                            vL_x(:, :, :, iv%beg:iv%end), vL_y(:, :, :, iv%beg:iv%end), vL_z(:, :, :, :), vR_x(:, :, :, iv%beg:iv%end), vR_y(:, :, :, iv%beg:iv%end), vR_z(:, :, :, :), &
                            norm_dir, weno_dir, &
                            is1, is2, is3)
            end if
        else

            call s_weno(v_vf(iv%beg:iv%end), &
                        vL_x(:, :, :, iv%beg:iv%end), vL_y(:, :, :, :), vL_z(:, :, :, :), vR_x(:, :, :, iv%beg:iv%end), vR_y(:, :, :, :), vR_z(:, :, :, :), &
                        norm_dir, weno_dir, &
                        is1, is2, is3)
        end if

        if (any(Re_size > 0)) then
            if (weno_Re_flux) then
                if (norm_dir == 2) then
                    !$acc parallel loop collapse(4) gang vector default(present)
                    do i = iv%beg, iv%end
                        do l = is3%beg, is3%end
                            do j = is1%beg, is1%end
                                do k = is2%beg, is2%end
                                    vL_prim_vf(i)%sf(k, j, l) = vL_y(j, k, l, i)
                                    vR_prim_vf(i)%sf(k, j, l) = vR_y(j, k, l, i)
                                end do
                            end do
                        end do
                    end do
                elseif (norm_dir == 3) then
                    !$acc parallel loop collapse(4) gang vector default(present)
                    do i = iv%beg, iv%end
                        do j = is1%beg, is1%end
                            do k = is2%beg, is2%end
                                do l = is3%beg, is3%end
                                    vL_prim_vf(i)%sf(l, k, j) = vL_z(j, k, l, i)
                                    vR_prim_vf(i)%sf(l, k, j) = vR_z(j, k, l, i)
                                end do
                            end do
                        end do
                    end do
                elseif (norm_dir == 1) then
                    !$acc parallel loop collapse(4) gang vector default(present)
                    do i = iv%beg, iv%end
                        do l = is3%beg, is3%end
                            do k = is2%beg, is2%end
                                do j = is1%beg, is1%end
                                    vL_prim_vf(i)%sf(j, k, l) = vL_x(j, k, l, i)
                                    vR_prim_vf(i)%sf(j, k, l) = vR_x(j, k, l, i)
                                end do
                            end do
                        end do
                    end do
                end if
            end if
        end if
        ! ==================================================================

    end subroutine s_reconstruct_cell_boundary_values_visc_deriv ! --------------------

    !>  The purpose of this subroutine is to employ the inputted
        !!      left and right cell-boundary integral-averaged variables
        !!      to compute the relevant cell-average first-order spatial
        !!      derivatives in the x-, y- or z-direction by means of the
        !!      scalar divergence theorem.
        !!  @param vL_vf Left cell-boundary integral averages
        !!  @param vR_vf Right cell-boundary integral averages
        !!  @param dv_ds_vf Cell-average first-order spatial derivatives
        !!  @param norm_dir Splitting coordinate direction
    subroutine s_apply_scalar_divergence_theorem(vL_vf, vR_vf, & ! --------
                                                 dv_ds_vf, &
                                                 norm_dir, &
                                                 ix, iy, iz, iv, &
                                                 dL, dim, buff_size_in)

        type(int_bounds_info) :: ix, iy, iz, iv

        integer :: buff_size_in, dim

        real(kind(0d0)), dimension(-buff_size_in:dim + buff_size_in) :: dL
        ! arrays of cell widths

        type(scalar_field), &
            dimension(iv%beg:iv%end), &
            intent(IN) :: vL_vf, vR_vf

        type(scalar_field), &
            dimension(iv%beg:iv%end), &
            intent(INOUT) :: dv_ds_vf

        integer, intent(IN) :: norm_dir

        integer :: i, j, k, l !< Generic loop iterators

        !$acc update device(ix, iy, iz, iv)

        ! First-Order Spatial Derivatives in x-direction ===================
        if (norm_dir == 1) then

            ! A general application of the scalar divergence theorem that
            ! utilizes the left and right cell-boundary integral-averages,
            ! inside each cell, or an arithmetic mean of these two at the
            ! cell-boundaries, to calculate the cell-averaged first-order
            ! spatial derivatives inside the cell.

            !$acc parallel loop collapse(3) gang vector default(present)
            do l = iz%beg, iz%end
                do k = iy%beg, iy%end
                    do j = ix%beg + 1, ix%end - 1
                        !$acc loop seq
                        do i = iv%beg, iv%end
                            dv_ds_vf(i)%sf(j, k, l) = &
                                1d0/((1d0 + wa_flg)*dL(j)) &
                                *(wa_flg*vL_vf(i)%sf(j + 1, k, l) &
                                  + vR_vf(i)%sf(j, k, l) &
                                  - vL_vf(i)%sf(j, k, l) &
                                  - wa_flg*vR_vf(i)%sf(j - 1, k, l))
                        end do
                    end do
                end do
            end do

            ! END: First-Order Spatial Derivatives in x-direction ==============

            ! First-Order Spatial Derivatives in y-direction ===================
        elseif (norm_dir == 2) then

            ! A general application of the scalar divergence theorem that
            ! utilizes the left and right cell-boundary integral-averages,
            ! inside each cell, or an arithmetic mean of these two at the
            ! cell-boundaries, to calculate the cell-averaged first-order
            ! spatial derivatives inside the cell.

            !$acc parallel loop collapse(3) gang vector default(present)
            do l = iz%beg, iz%end
                do k = iy%beg + 1, iy%end - 1
                    do j = ix%beg, ix%end
                        !$acc loop seq
                        do i = iv%beg, iv%end
                            dv_ds_vf(i)%sf(j, k, l) = &
                                1d0/((1d0 + wa_flg)*dL(k)) &
                                *(wa_flg*vL_vf(i)%sf(j, k + 1, l) &
                                  + vR_vf(i)%sf(j, k, l) &
                                  - vL_vf(i)%sf(j, k, l) &
                                  - wa_flg*vR_vf(i)%sf(j, k - 1, l))
                        end do
                    end do
                end do
            end do

            ! END: First-Order Spatial Derivatives in y-direction ==============

            ! First-Order Spatial Derivatives in z-direction ===================
        else

            ! A general application of the scalar divergence theorem that
            ! utilizes the left and right cell-boundary integral-averages,
            ! inside each cell, or an arithmetic mean of these two at the
            ! cell-boundaries, to calculate the cell-averaged first-order
            ! spatial derivatives inside the cell.

            !$acc parallel loop collapse(3) gang vector default(present)
            do l = iz%beg + 1, iz%end - 1
                do k = iy%beg, iy%end
                    do j = ix%beg, ix%end
                        !$acc loop seq
                        do i = iv%beg, iv%end
                            dv_ds_vf(i)%sf(j, k, l) = &
                                1d0/((1d0 + wa_flg)*dL(l)) &
                                *(wa_flg*vL_vf(i)%sf(j, k, l + 1) &
                                  + vR_vf(i)%sf(j, k, l) &
                                  - vL_vf(i)%sf(j, k, l) &
                                  - wa_flg*vR_vf(i)%sf(j, k, l - 1))
                        end do
                    end do
                end do
            end do

        end if
        ! END: First-Order Spatial Derivatives in z-direction ==============

    end subroutine s_apply_scalar_divergence_theorem ! ---------------------

    !>  Computes the scalar gradient fields via finite differences
        !!  @param var Variable to compute derivative of
        !!  @param grad_x First coordinate direction component of the derivative
        !!  @param grad_y Second coordinate direction component of the derivative
        !!  @param grad_z Third coordinate direction component of the derivative
        !!  @param norm Norm of the gradient vector
    subroutine s_compute_fd_gradient(var, grad_x, grad_y, grad_z, &
                                     ix, iy, iz, buff_size_in)

        type(scalar_field), intent(IN) :: var
        type(scalar_field), intent(INOUT) :: grad_x
        type(scalar_field), intent(INOUT) :: grad_y
        type(scalar_field), intent(INOUT) :: grad_z

        integer, intent(IN) :: buff_size_in

        integer :: j, k, l !< Generic loop iterators

        type(int_bounds_info) :: ix, iy, iz

        ix%beg = -buff_size_in; ix%end = m + buff_size_in; 
        if (n > 0) then
            iy%beg = -buff_size_in; iy%end = n + buff_size_in
        else
            iy%beg = -1; iy%end = 1
        end if

        if (p > 0) then
            iz%beg = -buff_size_in; iz%end = p + buff_size_in
        else
            iz%beg = -1; iz%end = 1
        end if

        !$acc update device(ix, iy, iz)

        !$acc parallel loop collapse(3) gang vector default(present)
        do l = iz%beg + 1, iz%end - 1
            do k = iy%beg + 1, iy%end - 1
                do j = ix%beg + 1, ix%end - 1
                    grad_x%sf(j, k, l) = &
                        (var%sf(j + 1, k, l) - var%sf(j - 1, k, l))/ &
                        (x_cc(j + 1) - x_cc(j - 1))
                end do
            end do
        end do

        if (n > 0) then
            !$acc parallel loop collapse(3) gang vector
            do l = iz%beg + 1, iz%end - 1
                do k = iy%beg + 1, iy%end - 1
                    do j = ix%beg + 1, ix%end - 1
                        grad_y%sf(j, k, l) = &
                            (var%sf(j, k + 1, l) - var%sf(j, k - 1, l))/ &
                            (y_cc(k + 1) - y_cc(k - 1))
                    end do
                end do
            end do
        end if

        if (p > 0) then
            !$acc parallel loop collapse(3) gang vector
            do l = iz%beg + 1, iz%end - 1
                do k = iy%beg + 1, iy%end - 1
                    do j = ix%beg + 1, ix%end - 1
                        grad_z%sf(j, k, l) = &
                            (var%sf(j, k, l + 1) - var%sf(j, k, l - 1))/ &
                            (z_cc(l + 1) - z_cc(l - 1))
                    end do
                end do
            end do
        end if

        ix%beg = -buff_size_in; ix%end = m + buff_size_in; 
        if (n > 0) then
            iy%beg = -buff_size_in; iy%end = n + buff_size_in
        else
            iy%beg = 0; iy%end = 0
        end if

        if (p > 0) then
            iz%beg = -buff_size_in; iz%end = p + buff_size_in
        else
            iz%beg = 0; iz%end = 0
        end if

        !$acc update device(ix, iy, iz)

        !$acc parallel loop collapse(2) gang vector default(present)
        do l = iz%beg, iz%end
            do k = iy%beg, iy%end
                grad_x%sf(ix%beg, k, l) = &
                    (-3d0*var%sf(ix%beg, k, l) + 4d0*var%sf(ix%beg + 1, k, l) - var%sf(ix%beg + 2, k, l))/ &
                    (x_cc(ix%beg + 2) - x_cc(ix%beg))
                grad_x%sf(ix%end, k, l) = &
                    (3d0*var%sf(ix%end, k, l) - 4d0*var%sf(ix%end - 1, k, l) + var%sf(ix%end - 2, k, l))/ &
                    (x_cc(ix%end) - x_cc(ix%end - 2))
            end do
        end do
        if (n > 0) then
            !$acc parallel loop collapse(2) gang vector default(present)
            do l = iz%beg, iz%end
                do j = ix%beg, ix%end
                    grad_y%sf(j, iy%beg, l) = &
                        (-3d0*var%sf(j, iy%beg, l) + 4d0*var%sf(j, iy%beg + 1, l) - var%sf(j, iy%beg + 2, l))/ &
                        (y_cc(iy%beg + 2) - y_cc(iy%beg))
                    grad_y%sf(j, iy%end, l) = &
                        (3d0*var%sf(j, iy%end, l) - 4d0*var%sf(j, iy%end - 1, l) + var%sf(j, iy%end - 2, l))/ &
                        (y_cc(iy%end) - y_cc(iy%end - 2))
                end do
            end do
            if (p > 0) then
                !$acc parallel loop collapse(2) gang vector default(present)
                do k = iy%beg, iy%end
                    do j = ix%beg, ix%end
                        grad_z%sf(j, k, iz%beg) = &
                            (-3d0*var%sf(j, k, iz%beg) + 4d0*var%sf(j, k, iz%beg + 1) - var%sf(j, k, iz%beg + 2))/ &
                            (z_cc(iz%beg + 2) - z_cc(iz%beg))
                        grad_z%sf(j, k, iz%end) = &
                            (3d0*var%sf(j, k, iz%end) - 4d0*var%sf(j, k, iz%end - 1) + var%sf(j, k, iz%end - 2))/ &
                            (z_cc(iz%end) - z_cc(iz%end - 2))
                    end do
                end do
            end if
        end if

        if (bc_x%beg <= -3) then
            !$acc parallel loop collapse(2) gang vector default(present)
            do l = iz%beg, iz%end
                do k = iy%beg, iy%end
                    grad_x%sf(0, k, l) = (-3d0*var%sf(0, k, l) + 4d0*var%sf(1, k, l) - var%sf(2, k, l))/ &
                                         (x_cc(2) - x_cc(0))
                end do
            end do
        end if
        if (bc_x%end <= -3) then
            !$acc parallel loop collapse(2) gang vector default(present)
            do l = iz%beg, iz%end
                do k = iy%beg, iy%end
                    grad_x%sf(m, k, l) = (3d0*var%sf(m, k, l) - 4d0*var%sf(m - 1, k, l) + var%sf(m - 2, k, l))/ &
                                         (x_cc(m) - x_cc(m - 2))
                end do
            end do
        end if
        if (n > 0) then
            if (bc_y%beg <= -3 .and. bc_y%beg /= -14) then
                !$acc parallel loop collapse(2) gang vector default(present)
                do l = iz%beg, iz%end
                    do j = ix%beg, ix%end
                        grad_y%sf(j, 0, l) = (-3d0*var%sf(j, 0, l) + 4d0*var%sf(j, 1, l) - var%sf(j, 2, l))/ &
                                             (y_cc(2) - y_cc(0))
                    end do
                end do
            end if
            if (bc_y%end <= -3) then
                !$acc parallel loop collapse(2) gang vector default(present)
                do l = iz%beg, iz%end
                    do j = ix%beg, ix%end
                        grad_y%sf(j, n, l) = (3d0*var%sf(j, n, l) - 4d0*var%sf(j, n - 1, l) + var%sf(j, n - 2, l))/ &
                                             (y_cc(n) - y_cc(n - 2))
                    end do
                end do
            end if
            if (p > 0) then
                if (bc_z%beg <= -3) then
                    !$acc parallel loop collapse(2) gang vector default(present)
                    do k = iy%beg, iy%end
                        do j = ix%beg, ix%end
                            grad_z%sf(j, k, 0) = &
                                (-3d0*var%sf(j, k, 0) + 4d0*var%sf(j, k, 1) - var%sf(j, k, 2))/ &
                                (z_cc(2) - z_cc(0))
                        end do
                    end do
                end if
                if (bc_z%end <= -3) then
                    !$acc parallel loop collapse(2) gang vector default(present)
                    do k = iy%beg, iy%end
                        do j = ix%beg, ix%end
                            grad_z%sf(j, k, p) = &
                                (3d0*var%sf(j, k, p) - 4d0*var%sf(j, k, p - 1) + var%sf(j, k, p - 2))/ &
                                (z_cc(p) - z_cc(p - 2))
                        end do
                    end do
                end if
            end if
        end if

    end subroutine s_compute_fd_gradient ! --------------------------------------

    subroutine s_finalize_viscous_module()

        integer :: i

        @:DEALLOCATE(Res)

        if (cyl_coord) then
            do i = 1, num_dims
                @:DEALLOCATE(tau_Re_vf(cont_idx%end + i)%sf)
            end do
            @:DEALLOCATE(tau_Re_vf(E_idx)%sf)
            @:DEALLOCATE(tau_Re_vf)
        end if
    end subroutine s_finalize_viscous_module

end module m_viscous
