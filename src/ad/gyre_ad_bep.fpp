! Module   : gyre_ad_bep
! Purpose  : adiabatic bounary eigenvalue problem solver
!
! Copyright 2013-2015 Rich Townsend
!
! This file is part of GYRE. GYRE is free software: you can
! redistribute it and/or modify it under the terms of the GNU General
! Public License as published by the Free Software Foundation, version 3.
!
! GYRE is distributed in the hope that it will be useful, but WITHOUT
! ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
! or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
! License for more details.
!
! You should have received a copy of the GNU General Public License
! along with this program.  If not, see <http://www.gnu.org/licenses/>.

$include 'core.inc'

module gyre_ad_bep

  ! Uses

  use core_kinds

  use gyre_ad_bound
  use gyre_ad_eqns
  use gyre_ad_diff
  use gyre_ad_vars
  use gyre_bep
  use gyre_ext
  use gyre_grid
  use gyre_grid_par
  use gyre_model
  use gyre_mode_par
  use gyre_num_par
  use gyre_osc_par
  use gyre_sol

  use ISO_FORTRAN_ENV

  ! No implicit typing

  implicit none

  ! Derived-type definitions

  type, extends (r_bep_t) :: ad_bep_t
     class(model_t), pointer      :: ml => null()
     type(ad_eqns_t), allocatable :: eq(:)
     type(ad_vars_t)              :: vr
     type(mode_par_t)             :: md_p
     type(osc_par_t)              :: os_p
     integer, allocatable         :: s(:)
     real(WP), allocatable        :: x(:)
  end type ad_bep_t

  ! Interfaces

  interface ad_bep_t
     module procedure ad_bep_t_
  end interface ad_bep_t

  interface sol_t
     module procedure sol_t_
  end interface sol_t

  ! Access specifiers

  private

  public :: ad_bep_t
  public :: sol_t

  ! Procedures

contains

  function ad_bep_t_ (ml, omega, gr_p, md_p, nm_p, os_p) result (bp)

    class(model_t), pointer, intent(in) :: ml
    real(WP), intent(in)                :: omega(:)
    type(grid_par_t), intent(in)        :: gr_p
    type(mode_par_t), intent(in)        :: md_p
    type(num_par_t), intent(in)         :: nm_p
    type(osc_par_t), intent(in)         :: os_p
    type(ad_bep_t)                      :: bp

    integer, allocatable         :: s(:)
    real(WP), allocatable        :: x(:)
    integer                      :: n_k
    type(ad_bound_t)             :: bd
    integer                      :: k
    type(ad_diff_t), allocatable :: df(:)
    real(WP)                     :: omega_min
    real(WP)                     :: omega_max

    ! Construct the ad_bep_t

    ! Build the grid

    call build_grid(ml, omega, gr_p, md_p, os_p, s, x)

    n_k = SIZE(s)

    ! Initialize the boundary conditions

    bd = ad_bound_t(ml, md_p, os_p)

    ! Initialize the difference equations

    allocate(df(n_k-1))

    do k = 1, n_k-1
       df(k) = ad_diff_t(ml, s(k), x(k), s(k+1), x(k+1), md_p, nm_p, os_p)
    end do

    ! Initialize the bep_t

    if (nm_p%restrict_roots) then
       omega_min = MINVAL(omega)
       omega_max = MAXVAL(omega)
    else
       omega_min = -HUGE(0._WP)
       omega_max = HUGE(0._WP)
    endif
    
    bp%r_bep_t = r_bep_t_(bd, df, omega_min, omega_max, nm_p) 

    ! Other initializations

    bp%ml => ml

    allocate(bp%eq(n_k))

    do k = 1, n_k
       bp%eq(k) = ad_eqns_t(ml, s(k), md_p, os_p)
    end do

    bp%vr = ad_vars_t(ml, md_p, os_p)

    bp%s = s
    bp%x = x

    bp%md_p = md_p
    bp%os_p = os_p

    ! Finish

    return

  end function ad_bep_t_

  !****

  function sol_t_ (bp, omega) result (sl)

    class(ad_bep_t), intent(inout) :: bp
    real(WP), intent(in)           :: omega
    type(sol_t)                    :: sl

    real(WP)      :: y(4,bp%n_k)
    type(r_ext_t) :: discrim
    integer       :: k
    real(WP)      :: xA(4,4)
    real(WP)      :: dy_dx(4,bp%n_k)
    real(WP)      :: H(4,4)
    real(WP)      :: dH(4,4)
    complex(WP)   :: y_c(4,bp%n_k)
    complex(WP)   :: dy_c_dx(4,bp%n_k)
    integer       :: i

    ! Calculate the solution vector y

    call bp%solve(omega, y, discrim)

    ! Calculate its derivatives

    !$OMP PARALLEL DO PRIVATE (xA)
    do k = 1, bp%n_k

       associate (x => bp%x(k))

         xA = bp%eq(k)%xA(x, omega)

         if (x /= 0._WP) then
            dy_dx(:,k) = MATMUL(xA, y(:,k))/x
         else
            dy_dx(:,k) = 0._WP
         endif

       end associate

    end do

    ! Convert to canonical form

    !$OMP PARALLEL DO PRIVATE (H, dH)
    do k = 1, bp%n_k

       associate (s => bp%s(k), x => bp%x(k))

         H = bp%vr%H(s, x, omega)
         dH = bp%vr%dH(s, x, omega)

         y_c(:,k) = MATMUL(H, y(:,k))

         if (x /= 0._WP) then
            dy_c_dx(:,k) = MATMUL(dH/x + H, y(:,k))
         else
            dy_c_dx(:,k) = 0._WP
         endif

       end associate

    end do

    ! Construct the sol_t

    sl = sol_t(bp%s, bp%x, CMPLX(omega, KIND=WP), c_ext_t(discrim))

    do i = 1, 4
       call sl%set_y(i, y_c(i,:), dy_c_dx(i,:))
    end do

    call sl%set_y(5, SPREAD(CMPLX(0._WP, KIND=WP), 1, bp%n_k), &
                     SPREAD(CMPLX(0._WP, KIND=WP), 1, bp%n_k))

    ! Finish

    return

  end function sol_t_

end module gyre_ad_bep
