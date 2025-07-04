import sys
from functools import partial
import ops.annotate
import ops.firesnake
from ops.firesnake import Snake
import ops.io
import pandas as pd

WELLS, TILES = ops.firesnake.load_well_tile_list(config['WELL_TILE_LIST'],include=config['INCLUDE_WELLS_TILES'])
TILES = [str(item).zfill(4) for item in TILES]
SBS_CYCLES = [config['SBS_CYCLE_FORMAT'].format(cycle=x) for x in config['SBS_CYCLES']]

# display options for saved .tif files (view in ImageJ)
channels = ('DAPI', 'SBS_G', 'SBS_T', 'SBS_A', 'SBS_C')
LUTS = [getattr(ops.io, config['LUTS'][x]) for x in channels]
DISPLAY_RANGES = [config['DISPLAY_RANGES'][x] for x in channels]

# set paramspaces if a paramsearch mode is selected
if config['MODE'] == 'paramsearch_segmentation':
    (config,
        nuclei_segmentation_paramspace,
        cell_segmentation_paramspace) = ops.firesnake.initialize_paramsearch(config)
elif config['MODE'] == 'paramsearch_read-calling':
    config,read_calling_paramspace = ops.firesnake.initialize_paramsearch(config)
elif config['MODE']!='process':
    raise ValueError(f'MODE="{config["MODE"]}" not recognized, use either "process" or "paramsearch"')
else:
    if any(map(lambda x: isinstance(x,list),[config['THRESHOLD_DAPI'],config['THRESHOLD_CELL'],config['THRESHOLD_READS']])):
        raise ValueError('Thresholds cannot be lists for MODE="process"')
    if isinstance(config['NUCLEUS_AREA'][0],list):
        raise ValueError('NUCLEUS_AREA cannot be a list of lists for MODE="process"')

# naming convention for input and processed files
input_files = partial(ops.firesnake.input_files,
                      directory=config['INPUT_DIRECTORY'])

processed_input = partial(ops.firesnake.processed_file,
                         directory=config['PROCESS_DIRECTORY'],
                         )

processed_output = partial(ops.firesnake.processed_file,
                         directory=config['PROCESS_DIRECTORY'],
                         temp_tags=config['TEMP_TAGS'],
                         )

rule all:
    input:
        # request individual files or list of files
        [expand(processed_input(x), zip, well=WELLS, tile=TILES)
            for x in config['REQUESTED_TAGS']],
           [config['PROCESS_DIRECTORY'] + '/' + x for x in config['REQUESTED_FILES']],

rule align_SBS:
    priority: -1
    input:
        input_files(config['SBS_INPUT_TAG'], SBS_CYCLES)
    output:
        processed_output('aligned.tif')
    run:
        Snake.align_SBS(output=output, data=input,
            display_ranges=DISPLAY_RANGES, luts=LUTS, wildcards = wildcards)


rule transform_LoG:
    priority: -1
    input:
        processed_input('aligned.tif')
    output:
        processed_output('log.tif')
    run:
        Snake.transform_log(output=output, data=input, skip_index=0,
            display_ranges=DISPLAY_RANGES, luts=LUTS)

rule compute_std:
    input:
        processed_input('log.tif')
    output:
        processed_output('std.tif')
    run:
        Snake.compute_std(output=output, data=input[0], remove_index=0)

rule find_peaks:
    input:
        processed_input('std.tif')
    output:
        processed_output('peaks.tif')
    run:
        Snake.find_peaks(output=output, data=input[0])

rule max_filter:
    """Dilates sequencing channels to compensate for single-pixel alignment error.
    """
    input:
        processed_input('log.tif')
    output:
        processed_output('maxed.tif')
    run:
        Snake.max_filter(output=output, data=input[0], width=config['MAXED_WIDTH'],
            remove_index=0, display_ranges=DISPLAY_RANGES[1:], luts=LUTS[1:])

rule segment:
    input:
        #processed_input('aligned.tif'),
        input_files(config['SBS_INPUT_TAG'], SBS_CYCLES[0]),
    output:
        processed_output('nuclei.tif'),
        processed_output('cells.tif'),
    run:
        if config['SEGMENT_METHOD'] == 'cell_2019':
            Snake.segment_cell_2019(
                output=output, 
                data=input[0],
                nuclei_threshold=config['THRESHOLD_DAPI'],
                nuclei_area_min=config['NUCLEUS_AREA'][0],
                nuclei_area_max=config['NUCLEUS_AREA'][1],
                cell_threshold=config['THRESHOLD_CELL'],
            )
        elif config['SEGMENT_METHOD'] == 'cellpose':
            # last cycle
            cycle = config['CELLPOSE']['CYTO_CYCLE']
            data = ops.io.read_stack(input[0])[cycle]
            Snake.segment_cellpose(
                output=output, 
                data=data, 
                dapi_index=0, 
                cyto_index=config['CELLPOSE']['CYTO_CHANNEL'],
                diameter=config['CELLPOSE']['DIAMETER'],
                )
        else:
            error = ('config entry SEGMENT_METHOD must be "cell_2019" or "cellpose", '
                     f'not {config["SEGMENT_METHOD"]}')
            raise ValueError(error)

rule extract_bases:
    input:
        processed_input('peaks.tif'),
        processed_input('maxed.tif'),
        processed_input('cells.tif'),
    output:
        processed_output('bases.csv')
    run:
        Snake.extract_bases(output=output, peaks=input[0], maxed=input[1],
            cells=input[2], threshold_peaks=config['THRESHOLD_READS'], wildcards=wildcards)

rule call_reads:
    input:
        processed_input('bases.csv'),
        processed_input('peaks.tif'),
    output:
        processed_output('reads.csv')
    run:
        Snake.call_reads(output=output, df_bases=input[0], peaks=input[1], percentile_flag = config['PERCENTILE_FLAG'],
               thresh = config['PERCENTILE_THRESH'])


rule call_cells:
    input:
        processed_input('reads.csv')
    output:
        processed_output('cells.csv')
    run:
        Snake.call_cells(output=output, df_reads=input[0])


rule annotate_SBS:
    input:
        processed_input('log.tif'),
        processed_input('reads.csv'),
    output:
        processed_output('annotate_SBS.tif'),
    run:
        luts = LUTS + [ops.annotate.GRMC, ops.io.GRAY]
        display_ranges = [(a/4, b/4) for a,b in DISPLAY_RANGES] + [[0, 4]]
        Snake.annotate_SBS(output=output, log=input[0], df_reads=input[1],
            display_ranges=display_ranges, luts=luts, compress=1)

rule annotate_segment:
    input:
        input_files(config['SBS_INPUT_TAG'], SBS_CYCLES[0]),
        processed_input('nuclei.tif'),
        processed_input('cells.tif'),
    output:
        processed_output('annotate_segment.tif'),
    run:
        luts = LUTS + [ops.io.GRAY, ops.io.GRAY]
        # display_ranges = [(a/4, b/4) for a,b in DISPLAY_RANGES] + [[0, 3], [0, 3]]
        Snake.annotate_segment(output=output, data=input[0], nuclei=input[1],
            cells=input[2], luts=luts, compress=1, display_ranges=DISPLAY_RANGES + [[0, 1]])


rule annotate_SBS_extra:
    input:
        processed_input('log.tif'),
        processed_input('peaks.tif'),
        processed_input('reads.csv'),
    output:
        processed_output('annotate_SBS_extra.tif'),
    run:
        luts = LUTS + [ops.annotate.GRMC, ops.io.GRAY, ops.io.GRAY]
        display_ranges = [(a/4, b/4) for a,b in DISPLAY_RANGES]
        display_ranges += [[0, 4], [0, config['THRESHOLD_READS']*4], [0, 30]]
        barcodes = pd.read_csv(config['BARCODE_TABLE'])

        Snake.annotate_SBS_extra(output=output, log=input[0], peaks=input[1],
            df_reads=input[2], barcode_table=config['BARCODE_TABLE'],
            sbs_cycles=config['SBS_CYCLES'],
            display_ranges=display_ranges[1:], luts=luts[1:], compress=1)


rule call_min_pheno:
     input:
        processed_input('cells.tif'),
        processed_input('nuclei.tif'),
     output:
        processed_output('coords_sbs.csv')
     run:
        Snake.extract_phenotype_minimal(output=output, data_phenotype=input[0], nuclei=input[1], wildcards=wildcards)


if config['MODE'] == 'paramsearch_segmentation':
    rule segment_nuclei_paramsearch:
        input:
            #processed_input('aligned.tif'),
            input_files(config['SBS_INPUT_TAG'], SBS_CYCLES[0]),
            # not used, just here to change the order of rule execution
            processed_input('log.tif'),
        output:
            processed_output(f'nuclei.{nuclei_segmentation_paramspace.wildcard_pattern}.tif')
        params:
            nuclei_segmentation = nuclei_segmentation_paramspace.instance
        run:
            Snake.segment_nuclei(output=output, data=input[0],
                threshold=params.nuclei_segmentation['THRESHOLD_DAPI'],
                area_min=params.nuclei_segmentation['NUCLEUS_AREA_MIN'],
                area_max=params.nuclei_segmentation['NUCLEUS_AREA_MAX'])

    rule segment_cells_paramsearch:
        input:
            input_files(config['SBS_INPUT_TAG'], SBS_CYCLES[0]),
            processed_input(f'nuclei.{nuclei_segmentation_paramspace.wildcard_pattern}.tif')
        output:
            processed_output(f'cells.{nuclei_segmentation_paramspace.wildcard_pattern}.{cell_segmentation_paramspace.wildcard_pattern}.tif')
        params:
            cell_segmentation = cell_segmentation_paramspace.instance
        run:
            Snake.segment_cells(output=output,
                data=input[0], nuclei=input[1], threshold=params.cell_segmentation['THRESHOLD_CELL'])

    rule segment_paramsearch_summary:
        input:
            #processed_input('aligned.tif'),
            data = input_files(config['SBS_INPUT_TAG'], SBS_CYCLES[0]),
            segmentations = [processed_input(f'nuclei.{nuclei_segmentation_paramspace.wildcard_pattern}.tif')]+
            [processed_input(f'cells.{nuclei_segmentation_paramspace.wildcard_pattern}.'
                f'{cell_segmentation_instance}.tif')
                for cell_segmentation_instance in cell_segmentation_paramspace.instance_patterns
                ]
        output:
            processed_output(f'segmentation_summary.{nuclei_segmentation_paramspace.wildcard_pattern}.'
                f'{"_".join(cell_segmentation_paramspace.instance_patterns)}.tif')
        run:
            Snake.summarize_paramsearch_segmentation(output=output,data=input.data[0],segmentations=input.segmentations,
                luts=LUTS[:2]+[ops.io.GLASBEY,]*len(input.segmentations)
                )

if config['MODE'] == 'paramsearch_read-calling':
    rule extract_bases_paramsearch:
        input:
            processed_input('peaks.tif'),
            processed_input('maxed.tif'),
            processed_input('cells.tif'),
        output:
            processed_output(f'bases.{read_calling_paramspace.wildcard_pattern}.csv')
        params:
            read_calling = read_calling_paramspace.instance
        run:
            Snake.extract_bases(output=output, peaks=input[0], maxed=input[1],
                cells=input[2], threshold_peaks=params.read_calling['THRESHOLD_READS'], wildcards=wildcards)

    rule call_reads_paramsearch:
        input:
            processed_input(f'bases.{read_calling_paramspace.wildcard_pattern}.csv'),
            processed_input('peaks.tif'),
        output:
            processed_output(f'reads.{read_calling_paramspace.wildcard_pattern}.csv')
        run:
            Snake.call_reads(output=output, df_bases=input[0], peaks=input[1], percentile_flag = config['PERCENTILE_FLAG'],
               thresh = config['PERCENTILE_THRESH'])

    rule call_reads_paramsearch_summary:
        input:
            barcodes=config['BARCODE_TABLE'],
            reads=expand([processed_input(f'reads.{read_calling_instance}.csv')
                for read_calling_instance in read_calling_paramspace.instance_patterns],
                zip, well=WELLS, tile=TILES),
            cells=expand(processed_input('cells.tif'), zip, well=WELLS, tile=TILES)
        output:
            table=(config['PROCESS_DIRECTORY'] + '/paramsearch_read-calling.summary.csv'),
            figure=(config['PROCESS_DIRECTORY'] + '/paramsearch_read-calling.summary.pdf')
        run:
            Snake.summarize_paramsearch_reads(output=[output.table],barcode_table=input.barcodes,
                reads_tables=input.reads,cells=input.cells,sbs_cycles=config['SBS_CYCLES_FOR_MAPPING'],figure_output=output.figure
                )

#
