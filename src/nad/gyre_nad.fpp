! Program  : gyre_nad
! Purpose  : nonadiabatic oscillation code
!
! Copyright 2013 Rich Townsend
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

program gyre_nad

  ! Uses

  use core_kinds, SP_ => SP
  use gyre_constants
  use core_parallel

  use gyre_ext
  use gyre_model
  use gyre_modepar
  use gyre_oscpar
  use gyre_numpar
  use gyre_gridpar
  use gyre_scanpar
  use gyre_outpar
  use gyre_bvp
  use gyre_ad_bvp
  use gyre_rad_bvp
  use gyre_nad_bvp
  use gyre_search
  use gyre_mode
  use gyre_input
  use gyre_output
  use gyre_util
  use gyre_version
  use gyre_grid
  use gyre_trad

  use ISO_FORTRAN_ENV

  ! No implicit typing

  implicit none

  ! Variables

  character(:), allocatable    :: filename
  integer                      :: unit
  real(WP), allocatable        :: x_ml(:)
  class(model_t), pointer      :: ml => null()
  type(modepar_t), allocatable :: mp(:)
  type(oscpar_t), allocatable  :: op(:)
  type(numpar_t), allocatable  :: np(:)
  type(gridpar_t), allocatable :: shoot_gp(:)
  type(gridpar_t), allocatable :: recon_gp(:)
  type(scanpar_t), allocatable :: sp(:)
  type(outpar_t)               :: up
  integer                      :: i
  type(oscpar_t), allocatable  :: op_sel(:)
  type(numpar_t), allocatable  :: np_sel(:)
  type(gridpar_t), allocatable :: shoot_gp_sel(:)
  type(gridpar_t), allocatable :: recon_gp_sel(:)
  type(scanpar_t), allocatable :: sp_sel(:)
  integer                      :: n_op_sel
  integer                      :: n_np_sel
  real(WP)                     :: x_i
  real(WP)                     :: x_o
  real(WP), allocatable        :: omega(:)
  real(WP), allocatable        :: x_sh(:)
  class(r_bvp_t), allocatable  :: ad_bp
  class(c_bvp_t), allocatable  :: nad_bp
  integer                      :: n_md_ad
  integer                      :: d_md_ad
  type(mode_t), allocatable    :: md_ad(:)
  integer                      :: n_md_nad
  integer                      :: d_md_nad
  type(mode_t), allocatable    :: md_nad(:)

  ! Initialize

  call init_parallel()

  call set_log_level($str($LOG_LEVEL))

  if(check_log_level('INFO')) then

     write(OUTPUT_UNIT, 100) form_header('gyre_nad ['//TRIM(version)//']', '=')
100  format(A)

     write(OUTPUT_UNIT, 110) 'Compiler         : ', COMPILER_VERSION()
     write(OUTPUT_UNIT, 110) 'Compiler options : ', COMPILER_OPTIONS()
110  format(2A)

     write(OUTPUT_UNIT, 120) 'OpenMP Threads   : ', OMP_SIZE_MAX
120  format(A,I0)
     
     write(OUTPUT_UNIT, 100) form_header('Initialization', '=')

  endif

  call init_trad()

  ! Process arguments

  call parse_args(filename)
     
  open(NEWUNIT=unit, FILE=filename, STATUS='OLD')

  call read_model(unit, x_ml, ml)
  call read_constants(unit)
  call read_modepar(unit, mp)
  call read_oscpar(unit, op)
  call read_numpar(unit, np)
  call read_shoot_gridpar(unit, shoot_gp)
  call read_recon_gridpar(unit, recon_gp)
  call read_scanpar(unit, sp)
  call read_outpar(unit, up)

  ! Loop through modepars

  d_md_ad = 128
  n_md_ad = 0

  allocate(md_ad(d_md_ad))

  d_md_nad = 128
  n_md_nad = 0

  allocate(md_nad(d_md_nad))

  mp_loop : do i = 1, SIZE(mp)

     if (check_log_level('INFO')) then

        write(OUTPUT_UNIT, 100) form_header('Mode Search', '=')

        write(OUTPUT_UNIT, 100) 'Mode parameters'

        write(OUTPUT_UNIT, 130) 'l :', mp(i)%l
        write(OUTPUT_UNIT, 130) 'm :', mp(i)%m
130     format(3X,A,1X,I0)

        write(OUTPUT_UNIT, *)

     endif

     ! Select parameters according to tags

     call select_par(op, mp(i)%tag, op_sel, last=.TRUE.)
     call select_par(np, mp(i)%tag, np_sel, last=.TRUE.)
     call select_par(shoot_gp, mp(i)%tag, shoot_gp_sel)
     call select_par(recon_gp, mp(i)%tag, recon_gp_sel)
     call select_par(sp, mp(i)%tag, sp_sel)

     n_op_sel = SIZE(op_sel)
     n_np_sel = SIZE(np_sel)

     $ASSERT(n_op_sel >= 1,No matching osc parameters)
     $ASSERT(n_np_sel >= 1,No matching num parameters)
     $ASSERT(SIZE(shoot_gp_sel) >= 1,No matching shoot_grid parameters)
     $ASSERT(SIZE(recon_gp_sel) >= 1,No matching recon_grid parameters)
     $ASSERT(SIZE(sp_sel) >= 1,No matching scan parameters)

     if (n_op_sel > 1 .AND. check_log_level('WARN')) then
        write(OUTPUT_UNIT, 140) 'Warning: multiple matching osc namelists, using final match'
140     format('!!',1X,A)
     endif
        
     if (n_np_sel > 1 .AND. check_log_level('WARN')) then
        write(OUTPUT_UNIT, 140) 'Warning: multiple matching num namelists, using final match'
     endif
        
     ! Set up the frequency array

     if (allocated(x_ml)) then
        x_i = x_ml(1)
        x_o = x_ml(SIZE(x_ml))
     else
        x_i = 0._WP
        x_o = 1._WP
     endif

     call build_scan(sp_sel, ml, mp(i), op_sel(n_op_sel), x_i, x_o, omega)

     ! Set up the shooting grid

     call build_grid(shoot_gp_sel, ml, mp(i), op_sel(n_op_sel), omega, x_ml, x_sh, verbose=.TRUE.)

     ! Set up the bvp's

     if(mp(i)%l == 0 .AND. op_sel(n_op_sel)%reduce_order) then
        allocate(ad_bp, SOURCE=rad_bvp_t(x_sh, ml, mp(i), op_sel(n_op_sel), np_sel(n_np_sel)))
     else
        allocate(ad_bp, SOURCE=ad_bvp_t(x_sh, ml, mp(i), op_sel(n_op_sel), np_sel(n_np_sel)))
     endif
 
     allocate(nad_bp, SOURCE=nad_bvp_t(x_sh, ml, mp(i), op_sel(n_op_sel), np_sel(n_np_sel)))

     ! Find modes

     n_md_ad = 0

     call scan_search(ad_bp, np_sel(n_np_sel), omega, process_root_ad)

     call prox_search(nad_bp, np_sel(n_np_sel), md_ad(:n_md_ad), process_root_nad)

     ! Clean up

     deallocate(ad_bp)
     deallocate(nad_bp)

  end do mp_loop

  ! Write the summary file
 
  call write_summary(up, md_nad(:n_md_nad))

  ! Finish

  close(unit)

  call final_parallel()

contains

  subroutine process_root_ad (omega, n_iter, discrim_ref)

    real(WP), intent(in)      :: omega
    integer, intent(in)       :: n_iter
    type(r_ext_t), intent(in) :: discrim_ref

    real(WP), allocatable :: x_rc(:)
    integer               :: n
    real(WP)              :: x_ref
    real(WP), allocatable :: y(:,:)
    real(WP)              :: y_ref(6)
    type(r_ext_t)         :: discrim
    type(mode_t)          :: md_new

    ! Build the reconstruction grid

    call build_grid(recon_gp_sel, ml, mp(i), op_sel(n_op_sel), [omega], x_sh, x_rc, verbose=.FALSE.)

    ! Reconstruct the solution

    x_ref = MIN(MAX(op_sel(n_op_sel)%x_ref, x_sh(1)), x_sh(SIZE(x_sh)))

    n = SIZE(x_rc)

    allocate(y(6,n))

    call ad_bp%recon(omega, x_rc, x_ref, y, y_ref, discrim)

    ! Create the mode

    md_new = mode_t(ml, mp(i), op_sel(n_op_sel), CMPLX(omega, KIND=WP), c_ext_t(discrim), &
                    x_rc, CMPLX(y, KIND=WP), x_ref, CMPLX(y_ref, KIND=WP))

    if (md_new%n_pg < mp(i)%n_pg_min .OR. md_new%n_pg > mp(i)%n_pg_max) return

    md_new%n_iter = n_iter
    md_new%chi = ABS(discrim)/ABS(discrim_ref)

    if (check_log_level('INFO')) then
       write(OUTPUT_UNIT, 120) md_new%mp%l, md_new%n_pg, md_new%n_p, md_new%n_g, &
            md_new%omega, real(md_new%chi), md_new%n_iter, md_new%n
120    format(4(2X,I8),3(2X,E24.16),2X,I6,2X,I7)
    endif

    ! Store it

    n_md_ad = n_md_ad + 1

    if (n_md_ad > d_md_ad) then
       d_md_ad = 2*d_md_ad
       call reallocate(md_ad, [d_md_ad])
    endif

    md_ad(n_md_ad) = md_new

    ! Prune it

    call md_ad(n_md_ad)%prune()

    ! Finish

    return

  end subroutine process_root_ad

!****

  subroutine process_root_nad (omega, n_iter, discrim_ref)

    complex(WP), intent(in)   :: omega
    integer, intent(in)       :: n_iter
    type(r_ext_t), intent(in) :: discrim_ref

    real(WP), allocatable    :: x_rc(:)
    integer                  :: n
    real(WP)                 :: x_ref
    complex(WP), allocatable :: y(:,:)
    complex(WP)              :: y_ref(6)
    type(c_ext_t)            :: discrim
    type(mode_t)             :: md_new

    ! Build the reconstruction grid

    call build_grid(recon_gp_sel, ml, mp(i), op_sel(n_op_sel), [REAL(omega)], x_sh, x_rc, verbose=.FALSE.)

    ! Reconstruct the solution

    x_ref = MIN(MAX(op_sel(n_op_sel)%x_ref, x_sh(1)), x_sh(SIZE(x_sh)))

    n = SIZE(x_rc)

    allocate(y(6,n))

    call nad_bp%recon(omega, x_rc, x_ref, y, y_ref, discrim)

    ! Create the mode

    md_new = mode_t(ml, mp(i), op_sel(n_op_sel), CMPLX(omega, KIND=WP), discrim, &
                    x_rc, y, x_ref, y_ref)

    md_new%n_iter = n_iter
    md_new%chi = ABS(discrim)/ABS(discrim_ref)

    if (check_log_level('INFO')) then
       write(OUTPUT_UNIT, 120) md_new%mp%l, md_new%n_pg, md_new%n_p, md_new%n_g, &
            md_new%omega, real(md_new%chi), md_new%n_iter, md_new%n
120    format(4(2X,I8),3(2X,E24.16),2X,I6,2X,I7)
    endif

    ! Store it

    n_md_nad = n_md_nad + 1

    if (n_md_nad > d_md_nad) then
       d_md_nad = 2*d_md_nad
       call reallocate(md_nad, [d_md_nad])
    endif

    md_nad(n_md_nad) = md_new

    ! Write it

    call write_mode(up, md_nad(n_md_nad), n_md_nad)

    ! If necessary, prune it

    if (up%prune_modes) call md_nad(n_md_nad)%prune()

    ! Finish

    return

  end subroutine process_root_nad

end program gyre_nad
