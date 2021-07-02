! Module   : gyre_tnad_eqns
! Purpose  : nonadiabatic (+turbulent convection) differential equations
!
! Copyright 2021 Rich Townsend & The GYRE Team
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

module gyre_tnad_eqns

  ! Uses

  use core_kinds

  use gyre_context
  use gyre_eqns
  use gyre_linalg
  use gyre_math
  use gyre_model
  use gyre_mode_par
  use gyre_model_util
  use gyre_nad_eqns
  use gyre_nad_trans
  use gyre_osc_par
  use gyre_point
  use gyre_state

  use ISO_FORTRAN_ENV

  ! No implicit typing

  implicit none

  ! Parameter definitions

  integer, parameter :: J_V = 1
  integer, parameter :: J_As = 2
  integer, parameter :: J_C_1 = 3
  integer, parameter :: J_GAMMA_1 = 4

  integer, parameter :: J_LAST = J_GAMMA_1

  ! Derived-type definitions

  type, extends (c_eqns_t) :: tnad_eqns_t
     private
     type(nad_eqns_t)           :: eq
     type(context_t), pointer   :: cx => null()
     type(point_t), allocatable :: pt(:)
     type(nad_trans_t)          :: tr
     real(WP), allocatable      :: coeff(:,:)
     real(WP)                   :: alpha_omg 
     real(WP)                   :: alpha_trb
  contains
     private
     procedure, public :: stencil
     procedure, public :: A
     procedure, public :: xA
     procedure, public :: y_trb
     procedure, public :: F_trb
  end type tnad_eqns_t

  ! Interfaces

  interface tnad_eqns_t
     module procedure tnad_eqns_t_
  end interface tnad_eqns_t

  ! Access specifiers

  private

  public :: tnad_eqns_t

  ! Procedures

contains

  function tnad_eqns_t_ (cx, md_p, os_p) result (eq)

    type(context_t), pointer, intent(in) :: cx
    type(mode_par_t), intent(in)         :: md_p
    type(osc_par_t), intent(in)          :: os_p
    type(tnad_eqns_t)                    :: eq

    type(osc_par_t) :: os_p_eq
    
    ! Construct the tnad_eqns_t, as a decorator around nad_eqns_t

    eq%cx => cx

    os_p_eq = os_p
    os_p_eq%variables_set = 'GYRE' 

    eq%eq = nad_eqns_t(cx, md_p, os_p_eq)

    eq%tr = nad_trans_t(cx, md_p, os_p)

    select case (os_p%time_factor)
    case ('OSC')
       eq%alpha_omg = 1._WP
    case ('EXP')
       eq%alpha_omg = -1._WP
    case default
       $ABORT(Invalid time_factor)
    end select

    eq%alpha_trb = os_p%alpha_trb

    eq%n_e = 6

    ! Finish

    return

  end function tnad_eqns_t_

  !****

  subroutine stencil (this, pt)

    class(tnad_eqns_t), intent(inout) :: this
    type(point_t), intent(in)         :: pt(:)

    class(model_t), pointer :: ml
    integer                 :: n_s
    integer                 :: i

    ! Calculate coefficients at the stencil points

    ml => this%cx%model()

    call check_model(ml, [I_V_2,I_AS,I_C_1,I_GAMMA_1])

    n_s = SIZE(pt)

    if (ALLOCATED(this%coeff)) deallocate(this%coeff)
    allocate(this%coeff(n_s, J_LAST))

    do i = 1, n_s

       $ASSERT(.NOT. ml%is_vacuum(pt(i)),Attempt to stencil at vacuum point)

       this%coeff(i,J_V) = ml%coeff(I_V_2, pt(i))*pt(i)%x**2
       this%coeff(i,J_AS) = ml%coeff(I_AS, pt(i))
       this%coeff(i,J_C_1) = ml%coeff(I_C_1, pt(i))
       this%coeff(i,J_GAMMA_1) = ml%coeff(I_GAMMA_1, pt(i))

    end do

    ! Set up stencil for the eq component

    call this%eq%stencil(pt)

    ! Set up stencil for the tr component

    call this%tr%stencil(pt)

    ! Store the stencil points for on-the-fly evaluations

    this%pt = pt

    ! Finish

    return

  end subroutine stencil

  !****

  function A (this, i, st)

    class(tnad_eqns_t), intent(in) :: this
    integer, intent(in)            :: i
    class(c_state_t), intent(in)   :: st
    complex(WP)                    :: A(this%n_e,this%n_e)
    
    ! Evaluate the RHS matrix

    A = this%xA(i, st)/this%pt(i)%x

    ! Finish

    return

  end function A

  !****

  function xA (this, i, st)

    class(tnad_eqns_t), intent(in) :: this
    integer, intent(in)            :: i
    class(c_state_t), intent(in)   :: st
    complex(WP)                    :: xA(this%n_e,this%n_e)

    complex(WP) :: A(6,6)
    real(WP)    :: Omega_rot_i
    complex(WP) :: l_i
    complex(WP) :: F_trb
    complex(WP) :: B(6,1)
    complex(WP) :: C(1,6)
    complex(WP) :: D

    ! Evaluate the log(x)-space RHS matrix

    associate ( &
         V => this%coeff(i,J_V), &
         Gamma_1 => this%coeff(i,J_GAMMA_1), &
         pt_i => this%cx%point_i())

      ! Set up original (nad) eqns

      A = this%eq%xA(i, st)

      ! Build matrices to add turbulent correction to y_2 (through a
      ! virtual y_trb variable)
      !
      !  dy/dx = A*y + B*y_trb
      !      0 = C*y + D*y_trb
      
      Omega_rot_i = this%cx%Omega_rot(pt_i)

      l_i = this%cx%l_e(Omega_rot_i, st)
    
      F_trb = this%F_trb(i, st)

      B(1,1) = -A(1,2)
      B(2,1) = V/Gamma_1 - 2._WP
      B(3,1) = -A(3,2)
      B(4,1) = -A(4,2)
      B(5,1) = -A(5,2)
      B(6,1) = -A(6,2)

      C(1,1) = F_trb*((l_i - 1._WP) + A(1,1))
      C(1,2) = F_trb*A(1,2)
      C(1,3) = F_trb*A(1,3)
      C(1,4) = F_trb*A(1,4)
      C(1,5) = F_trb*A(1,5)
      C(1,6) = F_trb*A(1,6)

      D = - 1._WP - F_trb*A(1,2)

      ! Eliminate y_trb to find xA
    
      xA = A - MATMUL(B, C)/D

    end associate

    ! Apply the variables transformation

    call this%tr%trans_eqns(xA, i, st)

    ! Finish

    return

  end function xA

  !****

  function y_trb (this, i, st, y)

    class(tnad_eqns_t), intent(inout) :: this
    integer, intent(in)               :: i
    class(c_state_t), intent(in)      :: st
    complex(WP), intent(in)           :: y(:)
    complex(WP)                       :: y_trb

    complex(WP) :: A(6,6)
    real(WP)    :: Omega_rot_i
    complex(WP) :: l_i
    complex(WP) :: F_trb
    complex(WP) :: C(6)
    complex(WP) :: D

    $CHECK_BOUNDS(SIZE(y), 6)
         
    ! Evaluate the turbulent force variable y_trb from
    ! the solution vector

    associate ( &
         pt_i => this%cx%point_i())

      ! Set up original (nad) eqns

      A = this%eq%xA(i, st)

      ! Evaluate y_trb
      
      Omega_rot_i = this%cx%Omega_rot(pt_i)

      l_i = this%cx%l_e(Omega_rot_i, st)
    
      F_trb = this%F_trb(i, st)

      C(1) = F_trb*((l_i - 1._WP) + A(1,1))
      C(2) = F_trb*A(1,2)
      C(3) = F_trb*A(1,3)
      C(4) = F_trb*A(1,4)
      C(5) = F_trb*A(1,5)
      C(6) = F_trb*A(1,6)

      D = - 1._WP - F_trb*A(1,2)

      y_trb = -DOT_PRODUCT(C, y)/D

    end associate

    ! Finish

    return

  end function y_trb

  !****

  function F_trb (this, i, st)

    class(tnad_eqns_t), intent(in) :: this
    integer, intent(in)            :: i
    class(c_state_t), intent(in)   :: st
    complex(WP)                    :: F_trb

    real(WP)    :: Omega_rot
    real(WP)    :: Omega_rot_i
    complex(WP) :: omega_c
    complex(WP) :: omega_c_r
    complex(WP) :: i_omega_c
    complex(WP) :: l_i
    real(WP)    :: H_r
    real(WP)    :: tau_conv
    complex(WP) :: nu_trb
         
    ! Evaluate the turbulent viscosity factor i*sigma*nu/(g r)

    associate ( &
         V => this%coeff(i,J_V), &
         As => this%coeff(i,J_AS), &
         c_1 => this%coeff(i,J_C_1), &
         Gamma_1 => this%coeff(i,J_GAMMA_1), &
         pt => this%pt(i), &
         pt_i => this%cx%point_i(), &
         x => this%pt(i)%x, &
         alpha_omg => this%alpha_omg, &
         alpha_trb => this%alpha_trb)

      if (pt%x > 0._WP .AND. As < 0._WP) then

         Omega_rot = this%cx%Omega_rot(pt)
         Omega_rot_i = this%cx%Omega_rot(pt_i)

         omega_c = this%cx%omega_c(Omega_rot, st)
         omega_c_r = this%cx%omega_c(Omega_rot, st, use_omega_r=.TRUE.)
         i_omega_c = (0._WP,1._WP)*sqrt(CMPLX(alpha_omg, KIND=WP))*omega_c

         l_i = this%cx%l_e(Omega_rot_i, st)

         H_r = MIN(1._WP/V, 1._WP) ! = H_P/r
         tau_conv = SQRT(-c_1/As)
       
         nu_trb = c_1*(H_r*alpha_trb)**2/(tau_conv*(1._WP + tau_conv*ABS(omega_c_r)/TWOPI))

         F_trb = i_omega_c*nu_trb

      else

         F_trb = 0._WP

      endif

    end associate

    ! Finish

    return

  end function F_trb

end module gyre_tnad_eqns
