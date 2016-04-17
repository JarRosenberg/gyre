! Module   : gyre_grid
! Purpose  : segmented grids
!
! Copyright 2013-2016 Rich Townsend
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

module gyre_grid

  ! Uses

  use core_kinds

  use gyre_point

  use ISO_FORTRAN_ENV

  ! No implicit typing

  implicit none

  ! Derived-type definitions

  type :: grid_t
     type(point_t), allocatable :: pt(:)
     integer                    :: n_k
   contains
     private
     procedure, public :: k_i
     procedure, public :: k_o
     procedure, public :: s_i
     procedure, public :: s_o
     procedure, public :: locate
  end type grid_t

  ! Interfaces

  interface grid_t
     module procedure grid_t_x_
     module procedure grid_t_subset_
     module procedure grid_t_resamp_
  end interface grid_t

  ! Access specifiers

  private

  public :: grid_t

  ! Procedures

contains

  function grid_t_x_ (x) result (gr)

    real(WP), intent(in) :: x(:)
    type(grid_t)         :: gr

    integer :: n_k
    integer :: k

    ! Construct a grid_t from the input abscissae x (with segment
    ! boundaries delineated by double points)

    n_k = SIZE(x)

    if (n_k > 0) then

       $ASSERT_DEBUG(ALL(x(2:) >= x(:n_k-1)),Non-monotonic data)
       
       allocate(gr%pt(n_k))

       gr%pt(1)%x = x(1)
       gr%pt(1)%s = 1

       do k = 2, n_k

          gr%pt(k)%x = x(k)

          if (x(k) == x(k-1)) then
             gr%pt(k)%s = gr%pt(k-1)%s + 1
          else
             gr%pt(k)%s = gr%pt(k-1)%s
          endif

       end do

    end if

    gr%n_k = n_k

    ! Finish

    return

  end function grid_t_x_

  !****

  function grid_t_subset_ (gr_base, x_min, x_max) result (gr)

    type(grid_t), intent(in) :: gr_base
    real(WP), intent(in)     :: x_min
    real(WP), intent(in)     :: x_max
    type(grid_t)             :: gr

    integer :: k_a
    integer :: k_b

    ! Construct a grid_t as a subset of gr_base

    k_a_loop : do k_a = 1, gr_base%n_k
       if (gr_base%pt(k_a)%x > x_min) exit k_a_loop
    end do k_a_loop

    if (k_a > 1) then
       if (gr_base%pt(k_a-1)%x == x_min) k_a = k_a-1
    endif

    k_b_loop : do k_b = gr_base%n_k, 1, -1
       if (gr_base%pt(k_b)%x < x_max) exit k_b_loop
    end do k_b_loop

    if (k_b < gr_base%n_k) then
       if (gr_base%pt(k_b+1)%x == x_max) k_b = k_b+1
    endif

    gr%pt = gr_base%pt(k_a:k_b)
    gr%n_k = SIZE(gr%pt)

    ! Finish

    return

  end function grid_t_subset_

  !****

  function grid_t_resamp_ (gr_base, dn) result (gr)

    type(grid_t), intent(in) :: gr_base
    integer, intent(in)      :: dn(:)
    type(grid_t)             :: gr

    integer  :: n_k_base
    integer  :: n_k
    integer  :: k
    integer  :: j
    integer  :: i
    real(WP) :: w

    $CHECK_BOUNDS(SIZE(dn),gr_base%n_k-1)

    ! Add points to the grid

    n_k_base = gr_base%n_k
    n_k = n_k_base + SUM(dn)

    allocate(gr%pt(n_k))

    k = 1

    cell_loop : do j = 1, n_k_base-1

       associate (pt_a => gr_base%pt(j), &
                  pt_b => gr_base%pt(j+1))

         if (pt_a%s == pt_b%s) then

            do i = 1, dn(j)+1

               w = REAL(i-1, WP)/REAL(dn(j)+1, WP)

               gr%pt(k)%s = pt_a%s
               gr%pt(k)%x = (1._WP-w)*pt_a%x + w*pt_b%x

               k = k + 1

            end do

         else

            $ASSERT(dn(j) == 0,Attempt to add points at cell boundary)

            gr%pt(k)%s = pt_a%s
            gr%pt(k)%x = pt_a%x

            k = k + 1

         endif

       end associate

    end do cell_loop

    gr%pt(k) = gr_base%pt(n_k_base)

    gr%n_k = n_k

    ! Finish

    return

  end function grid_t_resamp_

  !****

  function k_i (this, s)

    class(grid_t), intent(in) :: this
    integer, intent(in)       :: s
    integer                   :: k_i

    $ASSERT_DEBUG(s >= this%s_i(),Invalid segment)
    $ASSERT_DEBUG(s <= this%s_o(),Invalid segment)

    ! Return the index of the innermost point in segment s

    do k_i = 1, this%n_k
       if (this%pt(k_i)%s == s) exit
    end do

    ! Finish

    return

  end function k_i

  !****

  function k_o (this, s)

    class(grid_t), intent(in) :: this
    integer, intent(in)       :: s
    integer                   :: k_o

    $ASSERT_DEBUG(s >= this%s_i(),Invalid segment)
    $ASSERT_DEBUG(s <= this%s_o(),Invalid segment)

    ! Return the index of the outermost point in segment s

    do k_o = this%n_k, 1, -1
       if (this%pt(k_o)%s == s) exit
    end do

    ! Finish

    return

  end function k_o

  !****

  function s_i (this)

    class(grid_t), intent(in) :: this
    integer                   :: s_i

    ! Return the innermost segment of the grid

    s_i = this%pt(1)%s

    ! Finish

    return

  end function s_i

  !****

  function s_o (this)

    class(grid_t), intent(in) :: this
    integer                   :: s_o

    ! Return the outermost segment of the grid

    s_o = this%pt(this%n_k)%s

    ! Finish

    return

  end function s_o

  !****

  subroutine locate (this, x, s, back)

    class(grid_t), intent(in)     :: this
    real(WP), intent(in)          :: x
    integer, intent(out)          :: s
    logical, intent(in), optional :: back

    logical  :: back_
    integer  :: s_a
    integer  :: s_b
    integer  :: ds
    real(WP) :: x_i
    real(WP) :: x_o

    if (PRESENT(back)) then
       back_ = back
    else
       back_ = .FALSE.
    endif

    ! Locate the segment which brackets the abcissa x. If back is
    ! present and .TRUE., the search is done outside-in; otherwise, it
    ! is inside-out

    if (back_) then
       s_a = this%pt(this%n_k)%s
       s_b = this%pt(1)%s
       ds = -1
    else
       s_a = this%pt(1)%s
       s_b = this%pt(this%n_k)%s
       ds = 1
    endif

    seg_loop : do s = s_a, s_b, ds

       x_i = this%pt(this%k_i(s))%x
       x_o = this%pt(this%k_o(s))%x
         
       if (x >= x_i .AND. x <= x_o) exit seg_loop
       
    end do seg_loop

    ! Finish

    return

  end subroutine locate

end module gyre_grid
