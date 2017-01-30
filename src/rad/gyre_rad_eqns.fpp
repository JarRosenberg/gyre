! Module   : gyre_rad_eqns
! Purpose  : radial adiabatic differential equations
!
! Copyright 2013-2017 Rich Townsend
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

module gyre_rad_eqns

  ! Uses

  use core_kinds

  use gyre_eqns
  use gyre_grid
  use gyre_model
  use gyre_model_util
  use gyre_mode_par
  use gyre_osc_par
  use gyre_point
  use gyre_rad_vars
  use gyre_rot
  use gyre_rot_factory

  use ISO_FORTRAN_ENV

  ! No implicit typing

  implicit none

  ! Derived-type definitions

  type, extends (r_eqns_t) :: rad_eqns_t
     private
     class(model_t), pointer     :: ml => null()
     class(r_rot_t), allocatable :: rt
     type(rad_vars_t)            :: vr
     real(WP)                    :: alpha_om
   contains
     private
     procedure, public :: A
     procedure, public :: xA
  end type rad_eqns_t

  ! Interfaces

  interface rad_eqns_t
     module procedure rad_eqns_t_
  end interface rad_eqns_t

  ! Access specifiers

  private

  public :: rad_eqns_t

  ! Procedures

contains

  function rad_eqns_t_ (ml, gr, md_p, os_p) result (eq)

    class(model_t), pointer, intent(in) :: ml
    type(grid_t), intent(in)            :: gr
    type(mode_par_t), intent(in)        :: md_p
    type(osc_par_t), intent(in)         :: os_p
    type(rad_eqns_t)                    :: eq

    ! Construct the rad_eqns_t

    call check_model(ml, [I_V_2,I_AS,I_U,I_C_1,I_GAMMA_1])

    eq%ml => ml

    allocate(eq%rt, SOURCE=r_rot_t(ml, gr, md_p, os_p))
    eq%vr = rad_vars_t(ml, gr, md_p, os_p)

    select case (os_p%time_factor)
    case ('OSC')
       eq%alpha_om = 1._WP
    case ('EXP')
       eq%alpha_om = -1._WP
    case default
       $ABORT(Invalid time_factor)
    end select

    eq%n_e = 2

    ! Finish

    return

  end function rad_eqns_t_

  !****

  function A (this, pt, omega)

    class(rad_eqns_t), intent(in) :: this
    type(point_t), intent(in)     :: pt
    real(WP), intent(in)          :: omega
    real(WP)                      :: A(this%n_e,this%n_e)
    
    ! Evaluate the RHS matrix

    A = this%xA(pt, omega)/pt%x

    ! Finish

    return

  end function A

  !****

  function xA (this, pt, omega)

    class(rad_eqns_t), intent(in) :: this
    type(point_t), intent(in)     :: pt
    real(WP), intent(in)          :: omega
    real(WP)                      :: xA(this%n_e,this%n_e)

    real(WP) :: V_g
    real(WP) :: As
    real(WP) :: U
    real(WP) :: c_1
    real(WP) :: omega_c
    real(WP) :: alpha_om
    
    ! Evaluate the log(x)-space RHS matrix

    ! Calculate coefficients

    V_g = this%ml%coeff(I_V_2, pt)*pt%x**2/this%ml%coeff(I_GAMMA_1, pt)
    As = this%ml%coeff(I_AS, pt)
    U = this%ml%coeff(I_U, pt)
    c_1 = this%ml%coeff(I_C_1, pt)

    omega_c = this%rt%omega_c(pt, omega)

    alpha_om = this%alpha_om

    ! Set up the matrix

    xA(1,1) = V_g - 1._WP
    xA(1,2) = -V_g
      
    xA(2,1) = c_1*alpha_om*omega_c**2 + U - As
    xA(2,2) = As - U + 3._WP

    ! Apply the variables transformation

    xA = MATMUL(this%vr%G(pt, omega), MATMUL(xA, this%vr%H(pt, omega)) - &
                                                 this%vr%dH(pt, omega))

    ! Finish

    return

  end function xA

end module gyre_rad_eqns
